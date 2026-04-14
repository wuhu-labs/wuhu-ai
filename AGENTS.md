We are in the alignment programming rewriting phase.

All targets under AlignedTargets are being worked on. Sources/WuhuAI contains the legacy code that will be deleted after we reach feature parity.

Use the tool from github.com/wuhu-labs/swift-alignment-programming to verify the generated `.public.swift` before and after changes. There should not be any public APIs added or removed without explicit approval.

The `generate_public_interface` script from that repo is already installed on `PATH` on this machine, so you can run it directly from this package root without a full path. For example:

- `generate_public_interface --target AI`
- `generate_public_interface --target AI --output AI.public.swift`
