# MediaPipe pose landmark model

`pose_estimation_mediapipe_2023mar.onnx` is obtained from the
[OpenCV Model Zoo](https://github.com/opencv/opencv_zoo/tree/main/models/pose_estimation_mediapipe).

The model and the corresponding OpenCV Zoo example are distributed under the
Apache License 2.0.  It is the landmark half of MediaPipe Pose (BlazePose):
33 body keypoints with visibility plus metric world landmarks.  VRCRealtime
uses it locally to measure the owner's range (torso length) and body yaw
below the OCR-confirmed nameplate; frames never leave the machine.
