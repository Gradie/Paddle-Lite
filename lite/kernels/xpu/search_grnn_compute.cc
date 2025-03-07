// Copyright (c) 2019 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "lite/kernels/xpu/search_grnn_compute.h"
#include <algorithm>
#include <vector>
#include "lite/backends/xpu/xpu_header_sitter.h"
#include "lite/core/op_registry.h"

namespace paddle {
namespace lite {
namespace kernels {
namespace xpu {

void SearchGrnnCompute::PrepareForRun() {
  auto& ctx = this->ctx_->As<XPUContext>();
  int maxptr_size = ctx.GetRawContext()->max_ptr_size();
  new_offset_xpu_guard_ =
      TargetWrapperXPU::MallocScratchPad(XPU_MAX_LOD_SEQ_LEN * sizeof(int));
  maxs_xpu_guard_ =
      TargetWrapperXPU::MallocScratchPad(4 * maxptr_size * sizeof(float));

  idx_sorted_by_width_data_cpu.reset(new int[XPU_MAX_LOD_SIZE]);
  offset_cpu.reset(new int[XPU_MAX_LOD_SIZE]);
  new_offset_cpu.reset(new int[XPU_MAX_LOD_SEQ_LEN]);
}

void SearchGrnnCompute::prepare_layout(const operators::SearchGrnnParam& param,
                                       const paddle::lite::Tensor* bottom) {
  auto* idx_sorted_by_width = param.idx_sorted_by_width;
  auto* layout_input = param.layout_input;

  int dim0 = bottom->dims()[0];
  int dim1 = 1;
  if (bottom->dims().size() > 1) {
    dim1 = bottom->dims()[1];
  }
  int batch = bottom->lod()[0].size() - 1;
  auto& offset = bottom->lod()[0];

  idx_sorted_by_width->Resize({batch});
  std::vector<int> width;
  width.resize(batch);

  // sort sequences by width (descending) and find the largest width in the
  // batch
  for (int i = 0; i < batch; i++) {
    width[i] = offset[i + 1] - offset[i];
    idx_sorted_by_width_data_cpu[i] = i;
  }
  std::sort(idx_sorted_by_width_data_cpu.get(),
            idx_sorted_by_width_data_cpu.get() + batch,
            [&width](int a, int b) { return width[a] > width[b]; });
  int max_width = width[idx_sorted_by_width_data_cpu[0]];

  // start of reorganizing the input
  std::vector<size_t> new_offset;
  new_offset.resize(max_width + 1);
  new_offset[0] = 0;
  int j = batch - 1;
  int last_width = 0;
  int sub_row = 0;
  int sub_col = 0;

  for (int i = 1; i <= max_width;) {
    for (int k = j; k >= 0; --k) {
      if (width[idx_sorted_by_width_data_cpu[k]] > last_width) {
        sub_row = width[idx_sorted_by_width_data_cpu[k]] - last_width;
        sub_col = k + 1;
        for (int s = 0; s < sub_row; s++) {
          new_offset[i] = new_offset[i - 1] + sub_col;
          i++;
        }
        // move on
        last_width = width[idx_sorted_by_width_data_cpu[k]];
        j = k - 1;
        break;
      }
    }
  }

  // copying to the reorganized buffer
  if (bottom->dims().size() == 1) {
  } else {
    LoD new_lod;
    new_lod.push_back(new_offset);
    layout_input->set_lod(new_lod);
    layout_input->Resize({dim0, dim1});
  }
}

void SearchGrnnCompute::Run() {
  auto& param = this->template Param<param_t>();
  auto& ctx = this->ctx_->template As<XPUContext>();

  auto* bottom = param.x;
  auto* wi = param.wi;
  auto* wh = param.wh;
  auto* top = param.out;
  auto* tmp_buffer = param.tmp_buffer;
  auto* layout_input = param.layout_input;
  int cap_h = param.num_hidden;
  int cap_e = param.num_input;
  int cap_l = bottom->dims()[0];
  auto wi_max = param.__xpu__wi_max;
  auto wh_max = param.__xpu__wh_max;
  bool float_to_fix = param.__xpu__float_to_fix;
  CHECK(float_to_fix) << "W should be fixed point";

  int dim = 1;
  if (bottom->dims().size() > 1) {
    dim = bottom->dims()[1];
  }

  const auto& offset = bottom->lod()[0];
  LoD top_lod;
  top_lod.push_back(offset);
  top->set_lod(top_lod);
  std::vector<int64_t> top_dims_vec{cap_l, cap_h};
  top->Resize(top_dims_vec);
  auto* top_hidden = top->mutable_data<float>(TARGET(kXPU));
  const auto* dense_e2h = wi->data<int16_t>();
  const auto* dense_h2h = wh->data<int16_t>();

  // Prepare idx_sorted_by_width
  prepare_layout(param, bottom);
  int batch = bottom->lod()[0].size() - 1;
  int max_width = layout_input->lod()[0].size() - 1;
  const auto& new_offset = layout_input->lod()[0];
  auto* new_emb = layout_input->mutable_data<float>(TARGET(kXPU));
  int idx_size = batch;

  // Prepare offset and new_offset
  int offset_size = offset.size();
  int new_offset_size = new_offset.size();
  int* new_offset_xpu = reinterpret_cast<int*>(new_offset_xpu_guard_->addr_);
  float* maxs_xpu = reinterpret_cast<float*>(maxs_xpu_guard_->addr_);
  CHECK_LE(offset.size(), 64);
  CHECK_LE(new_offset.size(), 256);

  for (size_t i = 0; i < offset.size(); ++i) {
    offset_cpu[i] = offset[i];
  }
  for (size_t i = 0; i < new_offset.size(); ++i) {
    new_offset_cpu[i] = new_offset[i];
  }
  XPU_CALL(xpu_memcpy(new_offset_xpu,
                      new_offset_cpu.get(),
                      new_offset.size() * sizeof(int),
                      XPUMemcpyKind::XPU_HOST_TO_DEVICE));

  int r = xdnn::sequence_to_batch<float, int>(
      ctx.GetRawContext(),
      bottom->data<float>(),
      new_emb,
      dim,
      {idx_sorted_by_width_data_cpu.get(), idx_size, nullptr},
      {offset_cpu.get(), offset_size, nullptr},
      {new_offset_cpu.get(), new_offset_size, nullptr},
      false);
  CHECK_EQ(r, 0);

  // this buffer is used for book keeping info which will be used in bp
  // buffer also needed in bp, so make it larger
  tmp_buffer->Resize({20, cap_l, cap_h});
  auto* buffer_data = tmp_buffer->mutable_data<float>(TARGET(kXPU));
  // the internal hidden
  auto* hidden = buffer_data + 19 * cap_l * cap_h;

  // do-findmax
  int maxptr_size = ctx.GetRawContext()->max_ptr_size();
  std::vector<float> maxs_cpu(4 * maxptr_size, 0.0f);
  for (int idx = 0; idx < 3; idx++) {
    maxs_cpu[(idx + 1) * maxptr_size] = wi_max[idx];
  }
  XPU_CALL(xpu_memcpy(maxs_xpu,
                      maxs_cpu.data(),
                      4 * maxptr_size * sizeof(float),
                      XPUMemcpyKind::XPU_HOST_TO_DEVICE));
  r = xdnn::findmax<float>(
      ctx.GetRawContext(), new_emb, maxs_xpu, cap_l * cap_e);
  CHECK_EQ(r, 0);

  // precompute embedding to hidden
  for (int i = 0; i < 3; ++i) {
    const int16_t* data_b = dense_e2h + i * cap_e * cap_h;  // e2h, e2hr, e2hz
    float* data_c = buffer_data + i * cap_l * cap_h;  // w_x_e, wr_x_e, wz_x_e
    int r = xdnn::fc_fusion<float, int16_t, float, int16_t>(
        ctx.GetRawContext(),
        new_emb,
        data_b,
        data_c,  // data_a, data_b, data_c
        cap_l,
        cap_h,
        cap_e,  // m, n, k
        false,
        true,  // trans_a, trans_b
        maxs_xpu,
        maxs_xpu + maxptr_size * (i + 1),
        nullptr,  // max_a, max_b, max_c
        cap_e,
        cap_e,
        cap_h,  // lda, ldb, ldc
        1.0f,
        0.0f,  // alpha, beta
        nullptr,
        xdnn::Activation_t::LINEAR);  // bias, act
    CHECK_EQ(r, 0);
  }

  r = xdnn::search_grnn<float, int16_t>(ctx.GetRawContext(),
                                        cap_l,
                                        cap_h,
                                        cap_e,
                                        max_width,
                                        new_offset_xpu,
                                        buffer_data,
                                        dense_h2h,
                                        hidden,
                                        wh_max[0],
                                        wh_max[1],
                                        wh_max[2]);
  CHECK_EQ(r, 0);

  r = xdnn::batch_to_sequence<float, int>(
      ctx.GetRawContext(),
      hidden,
      top_hidden,
      cap_h,
      {idx_sorted_by_width_data_cpu.get(), idx_size, nullptr},
      {new_offset_cpu.get(), new_offset_size, nullptr},
      {offset_cpu.get(), offset_size, nullptr},
      false);
  CHECK_EQ(r, 0);
}

}  // namespace xpu
}  // namespace kernels
}  // namespace lite
}  // namespace paddle

REGISTER_LITE_KERNEL(search_grnn,
                     kXPU,
                     kFloat,
                     kNCHW,
                     paddle::lite::kernels::xpu::SearchGrnnCompute,
                     def)
    .BindInput("X", {LiteType::GetTensorTy(TARGET(kXPU))})
    .BindInput("Wi", {LiteType::GetTensorTy(TARGET(kXPU))})
    .BindInput("Wh", {LiteType::GetTensorTy(TARGET(kXPU))})
    .BindOutput("Out", {LiteType::GetTensorTy(TARGET(kXPU))})
    .BindOutput("tmp_buffer", {LiteType::GetTensorTy(TARGET(kXPU))})
    .BindOutput("idx_sorted_by_width",
                {LiteType::GetTensorTy(TARGET(kXPU), PRECISION(kInt32))})
    .BindOutput("layout_input", {LiteType::GetTensorTy(TARGET(kXPU))})
    .Finalize();
