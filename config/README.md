# Config templates

- `vdd_settings.example.xml` — generic Virtual-Display-Driver settings with
  one virtual monitor, no GPU binding. Start here.
- `vdd_settings.arc-b390.xml` — settings used on the reference host: one
  virtual monitor bound to `Intel(R) Arc(TM) B390 GPU,6` (guest PCI bus 6).

To use one of these, copy it next to the VDD driver package and pass it to
`install-vdd.ps1` (see the main README).
