@echo off

if not exist build mkdir build

pushd build

odin build ../ -collection:reliable_channel=../src/ -debug -out:example.exe

popd