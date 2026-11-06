/* tb_health.h — the receiver machine's own vital signs, shipped to the sender.
 *
 * WHY
 *
 * Every diagnostic in this project has been lopsided: the sender's numbers are
 * on the sender, and the receiver runs on a Mac being used as a monitor, with
 * no keyboard in front of it and its window full-screen. Getting a shell on it
 * mid-problem is exactly as awkward as it sounds, and that asymmetry is what
 * kept an intermittent stall alive for days.
 *
 * The receiver's stderr is already shipped to the sender and written to
 * ~/Library/Logs/TargetBridge/receiver.log, so anything printed here lands
 * beside the sender's own telemetry, in order, on the machine somebody is
 * actually sitting at.
 *
 * WHAT, AND WHY THESE
 *
 * The reference receiver is a 2020 Intel iMac driving 5K at 60 Hz — the most
 * thermally constrained part of the link by a wide margin, and the one we are
 * about to ask to run at a continuous full rate rather than roughly half.
 * Video playback already does exactly that, so this is not new load; it is load
 * we have never watched. Throttling would show up first as the GPU upload
 * stretching, which reads as "the link got slow" and would send the next
 * investigation straight back to the network.
 *
 *   thermal  NSProcessInfo's thermalState — the OS's own verdict, four levels.
 *   cpu      this process, as a percentage of one core.
 *   gpu      accelerator utilisation from IOKit's PerformanceStatistics, which
 *            is the only place macOS exposes it without private frameworks. Not
 *            present on every driver, hence optional.
 *   load     1-minute load average, to separate "we are busy" from "the machine
 *            is busy".
 */

#ifndef TB_HEALTH_H
#define TB_HEALTH_H

#ifdef __cplusplus
extern "C" {
#endif

/* Start reporting. Call once at startup; idempotent.
 *
 * Runs on its own thread rather than piggy-backing the per-second frame tick,
 * because the readings are not all cheap: the IORegistry walk for GPU
 * utilisation measured 1.5 ms (1.9 ms worst) on an M4 Pro and will be slower on
 * the Intel receiver. That fits inside a 16.7 ms frame with room to spare, so
 * it was not going to drop anything -- but a diagnostic sitting in the render
 * path is how this project has twice ended up measuring its own instrument. It
 * costs nothing to put it somewhere it cannot matter. */
void tb_health_start(void);

/* Hold off App Nap and other background throttling for the whole process.
 *
 * A display receiver is doing user-initiated work even when it is not the front
 * app: the picture must keep arriving while the user clicks something else on
 * this Mac. Without this, macOS suspends the render loop the moment the app goes
 * to the background -- measured at 92% of a 23-second window spent outside the
 * loop, cursor latency 18 SECONDS against a normal 4ms, the video queue filling
 * to 20/24 with 3600 dropped frames, and Metal left holding surfaces that were
 * never returned. From the user's side the receiver simply freezes on return and
 * only a relaunch clears it.
 *
 * Safe to call more than once; the assertion is held until the process exits. */
void tb_health_hold_awake(void);

/* Per-stage CPU accounting for the receive path.
 *
 * "63% of a core" is an aggregate, and an aggregate has never once been enough
 * to find anything in this project. Three stages are plausible and they want
 * different fixes: the kernel->userspace copy in read(), the memcpy that stages
 * a blob into a Metal upload buffer, and everything else in submitting a slice.
 * Splitting them is what named the sender's spike in a single run.
 *
 * Call with elapsed milliseconds; totals are folded into the [health] line. */
void tb_health_note_read(double ms);
void tb_health_note_upload_copy(double ms);
void tb_health_note_submit(double ms);

/* Latency samples, as opposed to the occupancy figures above.
 *
 * The three note_* calls above accumulate a SHARE of wall clock, which answers
 * "is this stage busy". Neither of the questions below is about busyness:
 *
 *   drawable_wait — how long [layer nextDrawable] blocked. Under vsync this is
 *   the wait for a free drawable, so it is the direct cost of
 *   maximumDrawableCount. If it is near zero the drawable count is not what is
 *   adding latency and lowering it would only risk throughput.
 *
 *   cursor_commit — the moment a cursor position reached the compositor. Only
 *   the CADENCE is recorded, not an absolute latency: the sender samples at
 *   120 Hz on a different machine, so without clock sync the gap between our own
 *   commits is the honest measurement. ~8ms means positions flow freely; ~17ms
 *   means something is gating them to the refresh rate.
 *
 * Reported as mean and max, because a mean alone hides exactly the stalls that
 * make a cursor feel bad. */
void tb_health_note_drawable_wait(double ms);
void tb_health_note_cursor_commit(void);

/* Drain the drawable wait for the PHASE REPORT, which is a control signal rather
 * than a diagnostic — see TB_PKT_PHASE. Returns 0 and writes nothing when no
 * samples have arrived since the last call, which is the normal state whenever
 * nothing is being presented; the caller should send no report at all in that
 * case rather than a mean of zero, since "no frames" and "no wait" would
 * otherwise look identical and the sender would read the latter as a good phase.
 *
 * Independent of the health report's own totals, so calling either does not
 * disturb the other. */
int tb_health_take_drawable_phase(double *mean_ms, long *n);

/* Arrival-to-commit for one cursor position: off the socket to on the
 * compositor, including any wait in the control queue. Excludes the network hop
 * by design — the sender's clock is on another machine and unsynchronised, so
 * adding it would be a guess dressed as a measurement. */
void tb_health_note_cursor_latency(double ms);

#ifdef __cplusplus
}
#endif

#endif
