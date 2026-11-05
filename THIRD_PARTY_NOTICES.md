# Third-party notices

## Native trackpad bridge

The private MultitouchSupport contact layout and callback declarations in
`CTrackpadBridge` were informed by/adapted from SwipeSwitcher:
https://github.com/haonlabs/SwipeSwitcher
Reviewed commit: c76041d9dde59815ec42d22f30a1a0532c51d3aa.
MyBar's recognition, subprocess protocol, browser dispatch and settings are separate implementations.
No SwipeSwitcher binary or service is required or launched.

MIT License

Copyright (c) 2026 Afiv Dicky Efendy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Capri desktop pet artwork and existing app icon

The existing character app icon is also excluded from the code license; no underlying character rights are granted.

The Pet feature reuses the user's supplied Capri fan-art sprite sheet from
`capri-anime`, unchanged. The artwork is not covered by the code's MIT license
and is not represented as commercially licensed or officially endorsed.
Its source attribution and rights notice are bundled in
`ThermoBar_ThermoBar.bundle/Pet/ASSET_RIGHTS.md`.
The browsing HUD, headphones and eye overlays are native MyBar drawings;
no episode footage or third-party app binaries are bundled.

## Mechanical keyboard switch recordings

The bundled `KeyboardSounds` recordings are from Mechanical Keyboard Simulator
by Thomas Lai: https://github.com/tplai/kbsim
Revision: ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4.
Copyright (c) Thomas Lai. MIT License. The complete permission and warranty notice
is retained alongside the recordings in `KeyboardSounds/LICENSE-kbsim.txt` inside
`ThermoBar_TypingFeedbackProtocol.bundle`. TheBar uses three generic press
recordings per switch, trims leading silence and adds short edge fades at load
time. No source application code is executed or downloaded at runtime.

---

The AppleSMC wire layout and decoding approach in `SMC.swift` were adapted from:

Fan Control — https://github.com/adilkairolla/fan-control

MIT License

Copyright (c) 2026 Adil Kairolla

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

The macOS 27 runtime assertion bridge in `ThermoBarMenuHelper/MenuBarAgentAssertion.swift`
was informed by/adapted from MenuBarHider's MenuBarAgentBridge and SystemItems:
https://github.com/happy666End/MenuBarHider

MIT License

Copyright (c) 2026 Saveliy Yudin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
