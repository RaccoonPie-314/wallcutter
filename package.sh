#!/bin/sh
set -e
cd "$(dirname "$0")"
rm -rf build wall_cutter.rbz
mkdir -p build/wall_cutter
cp src/wall_cutter.rb build/
cp src/cut_engine.rb src/cutout_tool.rb src/selftest.rb build/wall_cutter/
cp -R src/icons build/wall_cutter/icons
( cd build && zip -q -r ../wall_cutter.rbz wall_cutter.rb wall_cutter )
echo "built wall_cutter.rbz"

if [ "$1" = "install_dev" ]; then
  PLUGINS="$HOME/Library/Application Support/SketchUp 2026/SketchUp/Plugins"
  rsync -a --delete build/wall_cutter "$PLUGINS/"
  rsync -a build/wall_cutter.rb "$PLUGINS/"
  echo "installed to Plugins dir — restart SketchUp"
fi
