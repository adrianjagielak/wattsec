# Value calibration workflow

WattSec displays numbers assembled from several independent hardware sources
that don't perfectly agree (different sensors, units, update rates, and
intentional massaging by macOS). To make the displayed values converge on
physical truth, the app records everything it reads and we fit calibration
offline from days of real-world data.

## The loop

1. Run the app normally for a few days with **Diagnostics → Log Values** on
   (default). Include a few full charge and discharge cycles, some idle time,
   some heavy load, USB devices plugged/unplugged, and at least one session
   from 100% down below 10% if practical.
2. Collect `~/Library/Logs/WattSec/wattsec-*.jsonl` (one file per UTC day,
   one JSON object per sampling tick — 200 ms — ~300–400 MB/day, hard cap
   1 GB/day, auto-pruned after 14 days; zip them before transfer, JSONL
   compresses ~10×).
3. Analyze the data (see below), derive constants/curves, fold them into the
   app, and repeat until the residuals stop improving (expected: 1–3 rounds).

## Record format

One record per 200 ms sampling tick. Each source appears at the rate it
actually updates — logging a source faster than it refreshes would add
bytes, not information:

| Field | Cadence | Contents |
|---|---|---|
| `ts` | every record | ISO 8601 wall-clock timestamp |
| `uptime` | every record | seconds awake since boot (monotonic; pauses during sleep) |
| `smc` | every record (200 ms) | raw SMC watts: `PSTR` (system total), `PDTR` (DC in), `PDBR` (screen) |
| `derived` | every record | what the app computed: `wattageEMA`, `dcInEMA`, `gapW` (time-aligned unmetered gap), `avgW5m`, `avgDischargeW5m`, `interpWh`, `interpMaxWh` |
| `ioreport` | ~1 s (fresh delta ticks only) | per-channel SoC watts from Energy Model counters: `cpu`, `gpu`, `gpuSram`, `ane`, `dram`, `total`, plus `o_<label>` for every other channel. The counters are accumulating integrals, so 1 s sampling loses no energy — only attribution granularity. |
| `battery` | ~1 s (fresh gauge ticks only) | the **complete** AppleSmartBattery property table (binary blobs stripped). Voltage/Amperage are instantaneous values, so this cadence is what bounds integration accuracy. |

Lines with `"type": "meta"` mark app launches and day rollovers and carry
the hardware model, macOS version, and app version.

Interesting `battery` keys captured for calibration:

- `AppleRawCurrentCapacity`, `AppleRawMaxCapacity`, `NominalChargeCapacity`,
  `DesignCapacity` (all mAh) vs `CurrentCapacity` (user-facing %; **not**
  linear — macOS pins it near full and reserves near empty)
- `Voltage`, `Amperage`, `InstantAmperage`, `CellVoltage` (per-cell mV)
- `PowerTelemetryData` (macOS 13+): `SystemLoad`, `SystemPowerIn`,
  `BatteryPower`, and adapter fields — hardware-measured mW telemetry
- `ChargerData` (charging voltage/current, not-charging reason),
  `AdapterDetails`, `PowerOutDetails` (per-USB-port mW), `Temperature`,
  `FullyCharged`, `IsCharging`, `ExternalConnected`

## Planned analyses

1. **User-facing % ↔ raw capacity mapping.** Regress `CurrentCapacity`
   against `AppleRawCurrentCapacity / AppleRawMaxCapacity` across full
   cycles. Expect pinning at 100%, a reserve offset near 0%, and hysteresis
   between charge and discharge. Output: a piecewise curve so displayed Wh
   can use raw gauge data while still matching the menu-bar %.
2. **True Wh scale.** Integrate measured battery power
   (`Voltage × Amperage`) over full discharge segments and compare with
   `AppleRawMaxCapacity × nominal V` and the spec sheet Wh. Output: the
   correct nominal-voltage constant (or an SoC-dependent voltage curve)
   instead of the assumed 3.85 V/cell.
3. **Charger efficiency.** On AC: `PDTR − PSTR − BatteryPower(charging)`
   gives conversion loss; fit loss vs load to get the efficiency curve used
   by the "To Battery" estimate fallback.
4. **PSTR cross-check.** Compare `PSTR` with `PowerTelemetryData.SystemLoad`
   and, on battery, with `|Voltage × Amperage|`. Output: additive/
   multiplicative correction for the headline watts, and confirmation of
   `PowerTelemetryData` units/signs so it can be promoted to a display
   source.
5. **Unmetered gap behavior.** Distribution of `gapW` at idle with nothing
   plugged (should be ≈ VRM losses, a few % of PSTR) vs with USB devices.
   Output: baseline offset so USB/Ext shows ~0 W when nothing draws power.
6. **IOReport vs PSTR.** `ioreport.total + PDBR` vs `PSTR` under varied
   load to quantify what the Energy Model misses.

## Notes

- All fields are logged **raw, before smoothing** (except the explicitly
  named `derived` values), so filtering choices can be re-made offline.
- Timestamps are wall-clock; `uptime` disambiguates sleep gaps (wall time
  advances, uptime doesn't).
- Logging reuses the samples the app already takes (no extra sensor reads)
  and buffers writes into ~2 s batches — negligible power and I/O.
