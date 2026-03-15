# Add a live run command center, smarter completion recovery, and full-fidelity exports

## Features

- Add a small floating run panel that stays visible while tests are running and shows live progress like `3/50`, current site mix, success count, fail count, and health warnings.
- Let you move anywhere in the app during a run without losing control, with quick actions for pause, resume, stop, and jump into the active run.
- Add a deeper run control center where you can inspect every active session, recent errors, recovery attempts, network path changes, and batch checkpoints in one place.
- Reduce incomplete and ambiguous outcomes by adding a final verification pass for unsure, timeout, and interrupted sessions before they are treated as failed.
- Resume interrupted runs from the last safe checkpoint instead of forcing you to restart the whole batch.
- Show a clear post-run review queue for anything that still needs attention, so you can re-run only the uncertain items instead of the full batch.
- Add a full-fidelity export mode that keeps everything exactly as-is, including credentials, network details, configs, logs, and evidence history.
- Add per-run evidence bundles so each batch can be reviewed or shared as one complete record instead of piecing data together manually.

## Design

- Use a compact native floating card in the top corner with strong contrast, live counters, and a clean progress ring.
- Make the floating panel feel lightweight and non-blocking so it never gets in the way of navigation.
- Design the control center like an operations dashboard with clear sections, dense but readable metrics, and color-coded health states.
- Present uncertain outcomes as a review inbox with confidence badges, evidence chips, and obvious next actions.
- Keep export controls direct and explicit, with a clear “exact export” path and no masking by default.

## Pages / Screens

- **Floating Run Panel**: A persistent mini status view that follows you throughout the app during active tests.
- **Run Control Center**: A detailed screen for active batch status, per-session activity, checkpoints, recovery history, and run-wide controls.
- **Review Queue**: A focused screen that collects unsure, timed-out, or interrupted results and lets you retry only those items.
- **Run Evidence Detail**: A drill-down view showing the timeline, screenshots, network path, and recovery events for a single session or batch.
- **Exact Export Hub**: A screen for exporting complete raw data, full logs, and evidence bundles exactly as stored.