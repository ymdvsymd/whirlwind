default: check test

setup:
  npm install

check:
  npm run -s build:sdk
  moon check --target js

test:
  npm run -s build:sdk
  node --test sdk/*.test.mjs
  moon test --target js

mock: pack
  bash tests/e2e-ralph.sh mock

mock-flags: pack
  bash tests/e2e-ralph.sh mock-flags

live *args: pack
  bash tests/e2e-ralph.sh live {{args}}

live-flags: pack
  bash tests/e2e-ralph.sh live-flags

build:
  npm run -s build:sdk
  moon build --target js src/cmd/app

pack: build
  mkdir -p bin
  printf '\x23\x21/usr/bin/env node\n' > bin/whirlwind.js
  cat _build/js/debug/build/cmd/app/app.js >> bin/whirlwind.js
  sed -i '' "s/__VERSION__/$(node -p "require('./package.json').version")/" bin/whirlwind.js
  chmod +x bin/whirlwind.js

publish: pack
  npm publish --access public

run *args: build
  node _build/js/debug/build/cmd/app/app.js {{args}}

clean:
  moon clean

coverage:
  npm run -s build:sdk
  node --test --experimental-test-coverage sdk/*.test.mjs

fmt:
  moon fmt

info:
  moon info
