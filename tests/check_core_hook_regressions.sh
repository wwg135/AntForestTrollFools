#!/bin/sh
set -eu

root="$(dirname "$0")/.."
port="$root/PortEntry.m"
step="$root/antforest/StepSimulator.m"
manager="$root/antforest/AntForestManager.m"

printf '%s\n' '[1/5] Checking RPC original IMP keys are independent...'
grep -Fq 'PortRPCSendOriginalIMPKey' "$port"
grep -Fq 'PortRPCCallHandlerOriginalIMPKey' "$port"
if grep -Fq 'PortRPCOriginalIMPKey' "$port"; then
    echo '❌ legacy shared RPC IMP key remains'
    exit 1
fi

echo '[2/5] Checking RPC hooks materialize inherited methods before replacement...'
grep -Fq 'class_addMethod(cls, sendSel, original, types)' "$port"
grep -Fq 'class_addMethod(cls, handlerSel, original, types)' "$port"
grep -Fq 'method_setImplementation(directMethod, (IMP)portRPCSendProbe)' "$port"
grep -Fq 'method_setImplementation(directMethod, (IMP)portRPCCallHandlerProbe)' "$port"

echo '[3/5] Checking StepSimulator first-install marker semantics...'
grep -Fq 'if (!class_addMethod(cls, marker, (IMP)stepSimulatorHookMarker, "v@:")) return NO;' "$step"
grep -Fq 'if (original && !*original) *original = previous;' "$step"
if grep -Fq 'class_addMethod(cls, marker, (IMP)stepSimulatorHookMarker, "v@:")) return YES' "$step"; then
    echo '❌ StepSimulator still has inverted marker result'
    exit 1
fi

echo '[4/5] Checking Manor overflow cannot silently shift FIFO correlation...'
grep -Fq 'kMaxPendingManorRPCs' "$manager"
grep -Fq '[gManorPendingOps removeAllObjects]' "$manager"
grep -Fq 'pending overflow' "$manager"

echo '[5/5] Checking test/build tooling does not evaluate Xcode SDK until a build target is used...'
grep -Fq 'SDK = $(shell xcrun --sdk iphoneos --show-sdk-path)' "$root/Makefile"
grep -Fq 'CLANG = $(shell xcrun --sdk iphoneos --find clang)' "$root/Makefile"
grep -Fq 'LIPO = $(shell xcrun --sdk iphoneos --find lipo)' "$root/Makefile"

echo '✅ Core hook regression checks passed successfully!'
