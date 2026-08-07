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

#ifdef __cplusplus
}
#endif

#endif
