#!/bin/zsh
# Checks that every @rpath library the app (and its extensions) link is inside the bundle.
# Simulator builds can load frameworks from DerivedData, so a missing embed only shows up on device.
#   scripts/verify-bundle.sh [path/to/DanmuTV.app]
APP=${1:-build/DerivedData/Build/Products/Debug-appletvos/DanmuTV.app}
missing=0
for bin in "$APP/DanmuTV" "$APP/DanmuTV.debug.dylib" "$APP"/PlugIns/*.appex/*(.x); do
  [[ -f "$bin" ]] || continue
  for lib in $(otool -L "$bin" | awk '/@rpath\//{print $1}'); do
    rel=${lib#@rpath/}
    [[ "$rel" == *.debug.dylib ]] && continue
    if [[ ! -e "$APP/Frameworks/$rel" && ! -e "$APP/$rel" ]]; then
      echo "MISSING: $rel (linked by ${bin:t})"
      missing=1
    fi
  done
done
[[ $missing == 0 ]] && echo "bundle OK: all @rpath libraries embedded"
exit $missing
