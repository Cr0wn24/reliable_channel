@echo off

if not exist build mkdir build
pushd build

odin test ../tests/ -sanitize:address -collection:reliable_channel=../src/ -debug

popd