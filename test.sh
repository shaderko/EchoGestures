#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build
xcrun swiftc -Xcc -DACCELERATE_NEW_LAPACK -O Sources/DSP/EchoFeatures.swift Sources/DSP/CaptureHealth.swift Sources/DSP/RigidArrayClock.swift Sources/DSP/WorkspaceCalibration.swift Sources/DSP/ArrayMeasurement.swift Sources/DSP/ComplexProfile.swift Sources/DSP/TimingAnchor.swift Sources/DSP/MatchedFilter.swift Sources/Gestures/*.swift \
  Sources/Commands/Shortcut.swift Sources/Commands/CommandSession.swift Sources/Storage/LibraryStore.swift Tests/main.swift -framework Accelerate -o build/core-tests
build/core-tests
