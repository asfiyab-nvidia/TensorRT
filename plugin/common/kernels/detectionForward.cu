/*
 * SPDX-FileCopyrightText: Copyright (c) 1993-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "NvInfer.h"
#include "common/bboxUtils.h"
#include "common/kernels/kernel.h"
namespace nvinfer1
{
namespace plugin
{
pluginStatus_t detectionInference(
    cudaStream_t stream,
    const int N,
    const int C1,
    const int C2,
    const bool shareLocation,
    const bool varianceEncodedInTarget,
    const int backgroundLabelId,
    const int numPredsPerClass,
    const int numClasses,
    const int topK,
    const int keepTopK,
    const float confidenceThreshold,
    const float nmsThreshold,
    const CodeTypeSSD codeType,
    const DataType DT_BBOX,
    const void* locData,
    const void* priorData,
    const DataType DT_SCORE,
    const void* confData,
    void* keepCount,
    void* topDetections,
    void* workspace,
    bool isNormalized,
    bool confSigmoid,
    int scoreBits,
    const bool isBatchAgnostic)
{
    // Batch size * number bbox per sample * 4 = total number of bounding boxes * 4
    const int locCount = N * C1;
    // Do not clip the bounding box that goes outside the image
    const bool clipBBox = false;
    /*
     * shareLocation
     * Bounding box are shared among all classes, i.e., a bounding box could be classified as any candidate class.
     * Otherwise
     * Bounding box are designed for specific classes, i.e., a bounding box could be classified as one certain class or not (binary classification).
     */
    const int numLocClasses = shareLocation ? 1 : numClasses;

    size_t bboxDataSize = detectionForwardBBoxDataSize(N, C1, DT_BBOX);
    void* bboxDataRaw = workspace;

    pluginStatus_t status = decodeBBoxes(stream,
                                      locCount,
                                      codeType,
                                      varianceEncodedInTarget,
                                      numPredsPerClass,
                                      shareLocation,
                                      numLocClasses,
                                      backgroundLabelId,
                                      clipBBox,
                                      DT_BBOX,
                                      locData,
                                      priorData,
                                      bboxDataRaw,
                                      isBatchAgnostic);

    ASSERT_FAILURE(status == STATUS_SUCCESS);

    /*
     * bboxDataRaw format:
     * [batch size, numPriors (per sample), numLocClasses, 4]
     */
    // float for now
    void* bboxData;
    size_t bboxPermuteSize = detectionForwardBBoxPermuteSize(shareLocation, N, C1, DT_BBOX);
    void* bboxPermute = nextWorkspacePtr((int8_t*) bboxDataRaw, bboxDataSize);

    /*
     * After permutation, bboxData format:
     * [batch_size, numLocClasses, numPriors (per sample) (numPredsPerClass), 4]
     * This is equivalent to swapping axis
     */
    if (!shareLocation)
    {
        status = permuteData(stream,
                             locCount,
                             numLocClasses,
                             numPredsPerClass,
                             4,
                             DT_BBOX,
                             false,
                             bboxDataRaw,
                             bboxPermute);
        ASSERT_FAILURE(status == STATUS_SUCCESS);
        bboxData = bboxPermute;
    }
    /*
     * If shareLocation, numLocClasses = 1
     * No need to permute data on linear memory
     */
    else
    {
        bboxData = bboxDataRaw;
    }
    /*
     * Conf data format
     * [batch size, numPriors * param.numClasses, 1, 1]
     */
    const int numScores = N * C2;
    size_t scoresSize = detectionForwardPreNMSSize(N, C2);
    if (DT_SCORE == DataType::kHALF) scoresSize /= 2;
    void* scores = nextWorkspacePtr((int8_t*) bboxPermute, bboxPermuteSize);
    // need a conf_scores
    /*
     * After permutation, confData format:
     * [batch_size, numClasses, numPredsPerClass, 1]
     */
    status = permuteData(stream,
                         numScores,
                         numClasses,
                         numPredsPerClass,
                         1,
                         DT_SCORE,
                         confSigmoid,
                         confData,
                         scores);
    ASSERT_FAILURE(status == STATUS_SUCCESS);

    size_t indicesSize = detectionForwardPreNMSSize(N, C2);
    void* indices = nextWorkspacePtr((int8_t*) scores, scoresSize);

    size_t postNMSScoresSize = detectionForwardPostNMSSize(N, numClasses, topK);
    if (DT_SCORE == DataType::kHALF) postNMSScoresSize /= 2;
    size_t postNMSIndicesSize = detectionForwardPostNMSSize(N, numClasses, topK);
    void* postNMSScores = nextWorkspacePtr((int8_t*) indices, indicesSize);
    void* postNMSIndices = nextWorkspacePtr((int8_t*) postNMSScores, postNMSScoresSize);

    //size_t sortingWorkspaceSize = sortScoresPerClassWorkspaceSize(N, numClasses, numPredsPerClass, FLOAT32);
    void* sortingWorkspace = nextWorkspacePtr((int8_t*) postNMSIndices, postNMSIndicesSize);
    // Sort the scores so that the following NMS could be applied.
    float scoreShift = 0.f;
    if(DT_SCORE == DataType::kHALF && scoreBits > 0 && scoreBits <= 10)
        scoreShift = 1.f;
    status = sortScoresPerClass(stream,
                                N,
                                numClasses,
                                numPredsPerClass,
                                backgroundLabelId,
                                confidenceThreshold,
                                DT_SCORE,
                                scores,
                                indices,
                                sortingWorkspace,
                                scoreBits,
                                scoreShift);
    ASSERT_FAILURE(status == STATUS_SUCCESS);

    // NMS
    status = allClassNMS(stream, N, numClasses, numPredsPerClass, topK, nmsThreshold, shareLocation, isNormalized,
        DT_SCORE, DT_BBOX, bboxData, scores, indices, postNMSScores, postNMSIndices, false, scoreShift, true);
    ASSERT_FAILURE(status == STATUS_SUCCESS);

    // Sort the bounding boxes after NMS using scores
    status = sortScoresPerImage(stream,
                                N,
                                numClasses * topK,
                                DT_SCORE,
                                postNMSScores,
                                postNMSIndices,
                                scores,
                                indices,
                                sortingWorkspace,
                                scoreBits);
    ASSERT_FAILURE(status == STATUS_SUCCESS);

    // Gather data from the sorted bounding boxes after NMS
    status = gatherTopDetections(stream,
                                 shareLocation,
                                 N,
                                 numPredsPerClass,
                                 numClasses,
                                 topK,
                                 keepTopK,
                                 DT_BBOX,
                                 DT_SCORE,
                                 indices,
                                 scores,
                                 bboxData,
                                 keepCount,
                                 topDetections,
                                 scoreShift);
    ASSERT_FAILURE(status == STATUS_SUCCESS);

    return STATUS_SUCCESS;
}

} // namespace plugin
} // namespace nvinfer1
