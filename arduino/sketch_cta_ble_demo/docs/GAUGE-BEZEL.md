# Uniform gauge bezels

Inset rims surround ETA capsules, the distance tab and route windows. They
use shared theme-relative lighting: thickness 2 px, brightness 50%, contrast
40% by default. All three are enabled. Route center fills retain route colors;
route frames use the persistent neutral instrument surface.

Commands: `bezel on/off`, `bezel thickness 1..3`, `bezel brightness 0..100`,
`bezel contrast 0..100`, `bezel eta 0/1`, `bezel distance 0/1`, `bezel route 0/1`.
`status` reports values; `reset` restores defaults. Settings are RAM-only.

The ETA rim cache preserves borders during digit fades; navigation keeps
structural rims steady. Adjacent matching rim pixels are sent as horizontal
runs. No bevel variation or seed controls are retained.
