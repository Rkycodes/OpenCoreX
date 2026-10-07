# Scaling study graphs

All plots use the 60 measured rows in [programs.csv](../programs.csv).
Markers are measured configurations; connecting lines guide the eye and do not
represent additional measurements. Ratio means CPU cycles divided by offload
cycles: values above one favor offload. No confidence intervals are shown because
these are deterministic cycle simulations.

- [Offload advantage](offload-advantage.png): bypass and cached ratios at every latency and output count.
- [Cache benefit](cache-benefit.png): percentage cycle reduction relative to each method's own bypass baseline. Negative values mean caching hurts.
- [Whole-program cycles](whole-program-cycles.png): all 60 configurations on a common absolute cycle scale.
- [Output scaling](output-scaling.png): total cycles and cycles per output at L=20 with caching.

Each figure also has matching SVG (editable vector) and PDF exports.
Regenerate from the repository root with:

```sh
python3 scripts/plot_scaling.py
```

Requires Matplotlib. The script reads recorded counters and does not run simulations
or modify the measured source manifest. The graphs retain vector length 16, one
MAC lane, and fixed 1 MiB RAM; they do not measure larger vector working sets.
