# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.1.6] - 2026-09-12

### Added

- 新增可选的个人纠错学习：在支持的 macOS 输入框中有界跟踪本次听写后的修改，词库页展示捕获状态；不可靠的控件和终端可从历史补充纠正稿，或在原应用选中纠正后的片段按 `⌘⌥⇧L` 核对后保存。全程以软件最终输出与用户纠正稿为依据，不把 ASR 到 LLM 的整理差异当作人工纠正。
- 纠正记录只在本地累计，默认每 50 次已完成转写批量归纳，可设为 10–100 次或按天处理；同一请求包含未修改记录作为上下文，候选必须有真实纠正证据。按天模式在应用运行时处理以前日期的记录，每次最多 100 条。复用当前智能处理模型，提供手动归纳和失败重试；网络失败、取消或记录变化不会错误推进已处理批次。
- 新增候选词的归类、来源原句查看、编辑后确认、批量收录、忽略与恢复，以及独立的学习数据清除。确认的词复用现有 ASR 热词及 LLM 词库通路，不自动生成全局替换规则。新增持久化迁移、批次边界、Unicode 片段定位、证据验证、并发清理与界面渲染测试。
- Added opt-in personal correction learning with bounded macOS input-field tracking, a History correction editor, and a `⌘⌥⇧L` selected-text review shortcut. Learning compares final software output with user edits, not ASR-to-LLM rewrites.
- Corrections accumulate locally and are analyzed together after 50 completed dictations by default (configurable from 10 to 100), or in daily batches of up to 100 earlier-day records while the app runs. Unchanged records provide context only. Batches reuse the configured text-processing model and remain pending after failed, cancelled or stale requests.
- Added categorized suggestions, source evidence, editable approval, bulk acceptance, ignore/restore and learning-data deletion. Approved vocabulary uses existing ASR/LLM vocabulary paths without creating automatic global replacements. Added persistence, scheduling, Unicode anchoring, evidence validation, cleanup-race and UI-rendering coverage.

## [2.1.5] - 2026-09-06

### Fixed

- 修复长时间闲置/睡眠后首次听写整个应用假死只能强制退出的问题（三次复现：9/3、9/4、9/6）。根因经诊断日志与 sample 堆栈双重定位：`AudioCaptureService.start()` 在主线程上替换会话引擎（`self.engine = engine`），旧引擎随即在主线程 `AVAudioEngine dealloc`——dealloc 内部 `dispatch_sync` 到该引擎的 AVAudioIOUnit 队列，而该队列正卡在发往 coreaudiod 的 mach 消息上（睡眠唤醒后 HAL 无响应），主线程永久冻结；后续看门狗触发的 `fail()` 清理也需跳主线程，连环卡死。现将被替换的旧引擎改为在 `engineQueue` 上释放（退役块经 `withExtendedLifetime` 持有引用、随 GCD 块在后台队列释放），即使 coreaudiod 再卡，被堵住的也只是后台引擎队列：主线程与 15 秒 preparing 看门狗保持可用，会话按“启动超时”正常报错，用户可直接重试而不必强退。新增 DEBUG-only `testEngineHandle` 探测点与回归 `testStartRetiresPreviousEngineWithoutLeakingIt`（引擎确实被替换、退役引擎异步释放不泄漏、换新后仍可采集）。

## [2.1.4] - 2026-09-05

### Documentation

- Added the 2026-09-05 dictation reliability fix plan covering completion without automatic paste, realtime error cleanup, SSE response integrity, and reasoning deadlines, with reproduced evidence and acceptance criteria. Runtime fixes are not yet implemented.

### Fixed

- 实时错误后的会话不再永久卡在失败状态（可靠性方案 F2）。无同服务批量端点的实时供应商（如百炼）在无 partial 时收到 `.error`，清理链 `handle(event:) → fail() → resetIfCurrent() → drainProviderEventStream()` 会 `await providerEventTask?.value`——而执行该清理的正是事件消费任务本身，形成自等待死锁，会话永远停在 failed、任务与资源残留。现按路径区分语义：正常 stop() 仍走既有的有界 drain（runBoundedStopDrain，尾帧与事件保序）；失败/取消/重置/关停改用同步的 `terminateProviderEventStream()`（finish + cancel + 解除引用，内部零 await）；已进入处理函数的旧事件继续由会话/阶段守卫拦截。`resetIfCurrent` 的胶囊收尾改用新增的 `CapsuleController.hideIfIdle()`：仅在胶囊显示 idle 时隐藏，避免错误展示期间开启的新会话被旧重置误隐（onboarding 的无条件 hide 保留）。回归：审计复现 `testAuditFatalProviderEventResetsAfterErrorDisplay` 转绿；扩展现有 `testEarlyRealtimeErrorWithoutPartialFailsTheSession` 验证恢复空闲；新增 `testNewSessionSurvivesPreviousErrorDisplay`（错误展示期开新会话，旧计时结束后新会话仍在录音且可正常完成入历史）。

- 文字处理的 8 秒超时上限真正生效，取消等待也不再被不响应的任务挶持（可靠性方案 F4）。原 `reasoningWithTimeout` 用任务组同时等待模型任务与计时器，但任务组退出前必须等所有子任务结束——底层请求不响应取消时，超时声明形同虚设（实测 100 ms 超时实际 ~706 ms 才返回）。现改为一次性完成门控（ReasoningTimeoutGate，与 finishWithTimeout 的 ClaimGate 同形）：模型结果、截止时间、调用方取消三者先到先得，赢家唯一恢复 continuation 并立即取消输家（含计时器），不再等待不合作任务的 `.value`；`withTaskCancellationHandler` 覆盖等待前已取消的边界。协调器的 `reasoningTask` 改持包装任务（`startBoundedReasoning`），`cancel()`/`shutdown()` 取消包装即经门控联级取消底层请求与计时器；`stop()` 收到 `CancellationError` 不再误走原文回退/输出；清空 `reasoningTask` 前复核 sessionID，防止旧等待清掉新会话的任务引用。回归：`testAuditReasoningDeadlineDoesNotWaitForUncooperativeTask`（修复前红、修复后绿）、新增 `testReasoningWithTimeoutPropagatesCallerCancellation`（取消传播为 CancellationError 且底层任务收到取消）与 `testCancelDuringReasoningProducesNoOutput`（处理中取消：无完成快照、无历史、回空闲）。

- 流式文字处理不再把流内错误后的半截文字当作成功结果（可靠性方案 F3）。原 SSE 解析只拼接 `choices[].delta.content`、静默跳过无法解析的行，收到部分内容后发生流内错误（`event: error` 或载荷顶层 `error`）或异常 EOF 时会把不完整前缀当成功返回，上层因此跳过原文回退。新解析：`event:` 名称粘性应用到下一条 `data:`（`AsyncLineSequence` 会吞掉空行，SSE 空行事件边界在 `.lines` 上不可见，而 OpenAI 兼容端点每条 `data:` 行即完整 JSON 载荷，逐行分发即可）；错误载荷即时抛出（经 ProviderErrorSanitizer 净化，不落原始响应体）；`finish_reason` 仅 `stop` 视为正常完成，`length`/`content_filter`/工具调用等直接判不完整；EOF 时既无 `[DONE]` 也无正常 `stop` 则抛出新增的 `incompleteResponse`；只消费 `index == 0` 的候选，多候选不再混拼；注释/心跳/usage 事件不携带文本与完成信号；`[DONE]` 不能洗掉先发生的错误。协调器按既有策略回退完整原始转录。回归：`testAuditReasoningRejectsStreamErrorAfterPartialContent`（修复前红、修复后绿）与新增 `testReasoningStreamEndStateMatrix`（首事件即错误、无完成信号 EOF、length 后接 [DONE]、畸形 JSON、stop 免 [DONE]、心跳/usage 惰性、多候选不混拼）。

- 关闭自动粘贴时文字整理/翻译的会话不再卡死在“处理中”（可靠性方案 F1）。`DictationCoordinator.stop()` 在文字处理后处于 `processing` 阶段，但无粘贴分支的收尾固定按 `finalizing` 校验当前阶段，校验失败直接返回——剪贴板写入、历史保存、完成快照与重置全部跳过，胶囊一直停在处理中。现在收尾以实际所处阶段（`finalizing` 或 `processing`，状态机均允许进入 `completed`）继续，剪贴板、历史与完成反馈照常执行；自动粘贴分支不变。回归：`testAuditReasoningWithoutAutoPasteCompletesAndSavesHistory`（整理开+粘贴关：完成、入历史、回空闲）与 `testReasoningPasteEnabledWithoutTargetCompletesAndCopiesToClipboard`（粘贴开但无目标：走非粘贴收尾、历史 rawText/结果齐全、剪贴板按设置写入，测试用快照恢复真实剪贴板）。

## [2.1.3] - 2026-09-04

### Added

- Preparing-phase diagnostic logging to localize a reproducible first-dictation-after-long-idle hang (observed twice: session log stops right after "Dictation session started", the 15 s preparing watchdog never writes its failure entry, and the process has to be quit). `DictationCoordinator.start()` now brackets each suspension point that can stall on a wedged system service with a `.debug` "Dictation preparing step" entry — `audioPermission.begin/end`, `audioStart.begin/end`, `apiKeyRead.begin/end`, and `realtimeConnect.begin` (connect success is already covered by "Bailian realtime task started"), so after the next hang the last entry in the debug log names the step that never completed. `fail()` additionally logs a `.error` "Dictation session failing" entry as its first statement, before any teardown `await`: the existing "Dictation session failed" entry sits behind `audio.stop()` / media-resume / provider-cancel hops that can themselves block on a frozen MainActor, so without the entry marker a fired watchdog was indistinguishable from a never-fired one. Metadata carries step names and the sanitized error description only — no credentials or transcript text, per the log-sink gating convention. Helpers live in a new `DictationCoordinator+Diagnostics.swift` (static, logger passed explicitly) to keep the actor file under the 1200-line SwiftLint budget.

## [2.1.2] - 2026-08-27

### Removed

- The "Last Session Error" card in General settings (audit D6) is removed. It showed a persistent orange banner with the previous session's failure text and a manual "Clear" button, but it fired for every `.failed` session including the benign, self-explanatory `noSpeech` ("No speech was detected") outcome — pressing the key without speaking left a stale error sitting in settings that the user had to dismiss by hand, with no real value since the message already flashes on the capsule and is recorded in the debug log. Removed the whole feature end to end: `AppEnvironment.lastSessionError` / `recordSessionFailure` / `clearLastSessionError` / `lastFailedSessionID` / the `SessionFailure` model, the `LastSessionErrorCard` view and its render site in `UsageSettingsView`, and the `dashboard.lastError.title` / `dashboard.lastError.clear` strings in all three localizations. Session errors are unchanged everywhere else (capsule flash + debug log).

### Changed

- Cloud text processing (LLM cleanup / translation) on the OpenAI-compatible providers (Bailian/DashScope, Groq, custom, and the OpenAI default) now streams the response over SSE instead of blocking on the whole non-streaming reply, and is bounded by a tighter deadline with attribution logging. `ReasoningService.requestOpenAICompatible` sends `stream: true` + `stream_options: {"include_usage": true}` per Alibaba Model Studio's streaming docs and reads the reply through `session.bytes(for:).lines`, concatenating every `choices[].delta.content` fragment while skipping the `include_usage` terminator chunk (empty `choices`) and `[DONE]`; a non-2xx status still drains the body and surfaces the sanitized provider error. The motivation was a measured long latency tail on the non-streaming call: for the same ~50-token cleanup, direct probes against DashScope spiked to 13–19 s on the non-streaming endpoint while the streamed call stayed a few seconds (max ~2.5 s) with sub-second time-to-first-token. `DictationCoordinator.stop()` now bounds the reasoning call with a new 8 s wall-clock deadline via `reasoningWithTimeout` (the same claim-gate shape as `finishWithTimeout`): on timeout the in-flight task is cancelled and finalize falls back to the raw transcript, where previously only the coarse `request.timeoutInterval = 30` applied and a slow provider could stall finalize far longer. A new `.debug` "Text processing finished" log records `provider` / `model` / `enableThinking` / `elapsedMs` / `rawChars` / `resultChars` / `translation` / `outcome` (`ok` | `timeout` | `error`) for latency attribution — counts and flags only, never the transcript text, so a sensitive session leaks nothing through this sink. `enable_thinking` behaviour is unchanged (still sent explicitly for Bailian, and only when opted-in for custom), but the value now flows through a shared `ReasoningService.resolvedEnableThinking(provider:settings:)` helper reused by the log so the request and the attribution line can never disagree. Anthropic and Gemini paths are untouched (they keep the non-streaming `responseData`). New regressions: `testReasoningConcatenatesStreamedSSEDeltas` (multi-chunk delta concatenation, ignoring the usage terminator and `[DONE]`), and `testReasoningWithTimeoutReturnsValueBeforeDeadline` / `testReasoningWithTimeoutCancelsAndThrowsOnDeadline` (the deadline returns the value in time and cancels + throws `finalizeTimedOut` past it); the existing `testReasoningTimeoutFallsBackToRawTranscript` continues to cover the error→raw path. Full suite: 162 tests, 0 failures, 0 skips. The live streaming round-trip was additionally verified against DashScope with the exact request body (HTTP 200, `content-type: text/event-stream`, 7 delta frames, usage on the final chunk).


## [2.1.1] - 2026-08-25

### Fixed

- The default push-to-talk hotkey (Right Command, and every other modifier-only key: left/right Shift/Option/Control, Fn) is triggerable again after v2.1.0 broke it — pressing the key did nothing at all. v2.1.0 gated the modifier-only press/release decision on a live `CGEventSource.keyState(.combinedSessionState, key:)` read (plus a matching reconcile when the tap re-enabled), intending to disambiguate left vs right modifiers that share one `CGEventFlags` bit. Inside the event tap that read does not reliably reflect a modifier key's state at `.flagsChanged` delivery time, so `isNowPressed` stayed `false` and the key never registered — while regular combo keys (e.g. `Command+0`), which take the untouched keyDown path, kept working. `HotkeyService.handle()` is reverted verbatim to the v2.0.10 mask-only decision (`flags.intersection(descriptor.modifiers) == descriptor.modifiers`); the `modifierOnlyPressedState` helper and its unit test are removed. That test only asserted the pure boolean AND on a hand-fed `physicalKeyDown`, never the runtime `keyState` read that actually failed, so the suite stayed green through the regression — the live event-tap path is not exercisable in CI or a headless sandbox, so this fix must be verified on-device. The left/right-same-modifier edge case the v2.1.0 change chased is reintroduced as a documented known limitation, to be fixed later by reading the device-specific modifier bit (e.g. `NX_DEVICERCMDKEYMASK`) from the event itself rather than a global query.
- Two statements in the v2.1.0 release notes that did not match the shipped implementation are corrected in `docs/releases/v2.1.0.md` (both the Chinese and English sections), and the published GitHub Release body was re-uploaded from the corrected file so the tag's notes and the repo no longer disagree. First, the unit-test count read "116 → 159": 159 was measured before the NEW-5 revert and on a run where two keychain tests silently `XCTSkip`-ed, whereas the shipped tree measures `Executed=160, Failures=0, Skipped=0` — the notes now read "116 → 160". Second, the release-pipeline bullet credited P2-19 with switching "DMG packaging to a unique mountpoint"; that was an intermediate approach overturned during the release, because Finder can only resolve `tell disk "<name>"` for volumes mounted under `/Volumes` (an arbitrary mountpoint fails with `-1728`, which broke the `build` job on both architectures), so the shipped script keeps the mountpoint under `/Volumes` and moves the uniqueness into the volume name — the bullet now reads "unique volume name". Documentation only: no artifacts, checksums, appcasts, or the `v2.1.0` tag were touched.

## [2.1.0] - 2026-08-24

### Fixed

- The media-pause adapter (`MediaPlaybackController.runAdapter` in `AudioCueService.swift`) no longer blocks on an undrained stderr pipe or leaves a SIGTERM-ignoring child running: this is the same defect flagged as NEW-2 (the adapter's `standardError = Pipe()` was never read, the timeout path only called `terminate()`, and `waitUntilExit()` blocked), and it was fixed when `runAdapter` was migrated to the shared `SupervisedProcess.run` helper as part of P1-11/NEW-4 (commit `707fa8cb`). `SupervisedProcess` drains both stdout and stderr continuously via `readabilityHandler` with a 512 KB per-stream cap, so a chatty adapter writing past the ~64 KB kernel pipe buffer can no longer wedge the child, and it escalates SIGTERM → `killGrace` → SIGKILL on wall-clock timeout or cooperative cancellation, so a child that ignores SIGTERM is still reaped. Because `runAdapter` routes entirely through `SupervisedProcess.run`, NEW-2's two properties are locked in transitively by the existing `SupervisedProcessTests.testStderrIsDrainedAndNeverBlocksTheChild` (a child writing ~700 KB to stderr still exits 0 with stderr captured exactly at the 512 KiB cap) and `testTimeoutEscalatesToSIGKILLWhenChildIgnoresSIGTERM` (a `$SIG{TERM}='IGNORE'` child is brought down within timeout + killGrace); the private `nonisolated static runAdapter` has no test seam that does not require a real bundled perl adapter binary, so no redundant AudioCueService-level test is added (audit NEW-2).
- A slow or erroring non-streaming reasoning call (LLM cleanup / translation) can no longer block finalize or lose the user's transcript, and that safety net is now locked in by a regression test. `ReasoningService` already pins an independent `request.timeoutInterval = 30` on every provider POST through the shared `jsonRequest(url:body:)` builder (used verbatim by the OpenAI-compatible, Anthropic, and Gemini paths), and `DictationCoordinator.stop()` already wraps the reasoning call in a `Task` whose `catch` sets `finalText = normalizedRawText` (the raw transcript), logs a warning, and flashes `capsule.polishingFallback`, so a hung / slow / erroring reasoning call cannot wedge finalize — the session still inserts and saves the raw text and reaches `.completed` instead of parking in `.processing`. No production behavior change was needed for the fix itself; the audit item was already satisfied in code and this commit closes it by adding coverage. The new coordinator-level regression `testReasoningTimeoutFallsBackToRawTranscript` drives a full session whose reasoning provider — a `ReasoningStubURLProtocol` on the injected reasoning `URLSession` — returns HTTP 500, standing in for a timed-out / erroring provider so `ReasoningService.process` throws, and asserts (a) the reasoning POST was actually attempted (so the throw path is genuinely exercised, not skipped), (b) the session reaches `.completed` and never enters `.failed`, (c) the RAW transcript (`"hello raw world"`) is exactly what gets inserted and what lands in history (both `text` and `rawText`), and (d) `stop()` returns well under 10 s so finalize did not hang. Reaching `.completed` requires the insertion path (the default `automaticallyPasteTranscription` routes finalize through `.inserting`), and the real `TextInsertionService.insert` gates on `AXIsProcessTrusted()` — false on CI — so a minimal DEBUG-only `TextInsertionService.insertOverride` seam (mirroring the existing `capturedTargetOverride` `#if DEBUG` seam) lets the test stub insertion and capture the delivered text; release builds never compile the seam and always run the real AX/paste pipeline. Follow-ups noted but intentionally left unchanged as out of scope for this test-closure: the 30 s reasoning timeout is coarse (tightening it is a user-visible behavior change), and a reasoning-enabled session with `automaticallyPasteTranscription` disabled parks in `.processing` because `stop()`'s completion guard expects `.finalizing` (a pre-existing edge unrelated to the reasoning fallback) (audit P2-5).

- The dictation session no longer computes a smoothed microphone level on every audio frame only to discard it: `AudioConverterBox.emit` ran `AudioCaptureService.normalizedLevel` (a `20*log10` + exponential-smoothing step) and invoked `onLevel` once per ~20 ms frame — roughly fifty times a second — yet `DictationCoordinator` wired `onLevel: { _ in }`, so for the entire dictation path that per-frame log/smoothing was pure wasted work. `onLevel` is now an optional `(@Sendable (Float) -> Void)?` (default nil) threaded unchanged from `AudioCaptureService.start(...)` through `startEngineSession` into `AudioConverterBox`, and `emit` gates the smoothing + callback behind `if let onLevel { … }`, so a session with no level consumer skips the computation entirely — that is the win. The `onFrame(data, rms)` audio path (the RMS the `SpeechActivityGate` consumes) is completely untouched; only the metering side path is gated, and `DictationCoordinator` now passes `onLevel: nil`. Onboarding's mic-test capsule is a REAL consumer and is deliberately preserved unchanged: `OnboardingView` still passes its `{ level in … updateLevel(level, …) }` closure, which promotes to the new optional parameter with no edit and keeps the level flowing for the whole onboarding session. Gating cannot corrupt the smoothing accumulator because `onLevel` is an immutable `let` fixed once at `start` (constant per session), so it never flips between frames. The new regression `testOnLevelSkippedWhenCallbackAbsent` drives `AudioConverterBox` with `onLevel == nil` and asserts a DEBUG `levelComputations` seam (shaped like the P2-20 `allocationsUnderLock` read-under-lock accessor) stays 0, then drives it with a real callback and asserts the counter goes above 0 and that every computed level is delivered to the callback (audit P3-7).
- Having the control panel open during dictation no longer re-renders the entire panel at the audio frame rate: `AppEnvironment` is the app's single `ObservableObject` and it published BOTH the ~50 Hz dictation state and all of the low-frequency app state (`settings`, `transcriptions`, `permissions`, `microphones`, `dictionaryWords`, `modelInstallationState`, the error channels) through the same `objectWillChange`. SwiftUI subscribes to an `ObservableObject` as a whole and never per property, so each `@Published private(set) var dictation = DictationSnapshot.idle` write from the coordinator's snapshot handler — one per audio frame while recording, i.e. roughly fifty per second, each carrying a new `audioLevel` and a growing `partialText` — invalidated every view holding `@EnvironmentObject var environment: AppEnvironment`. That is the whole control panel: `ControlPanelView` and its sidebar, `HistoryView`'s record list, and every settings form (`UsageSettingsView`, `DictationSettingsView`, `ProcessingSettingsView`, `VocabularyRulesView`, `PrivacyDiagnosticsView`) re-evaluated `body` fifty times a second for every second of dictation, even though repo-wide grep confirms not one of those views reads the dictation state at all — they were paying for a stream none of them consumes. The per-frame state now lives on a new `DictationSessionModel: ObservableObject` (`Native/Sources/App/DictationSessionModel.swift`) owning a single `@Published private(set) var snapshot: DictationSnapshot` plus a `phase` convenience accessor, and `AppEnvironment` holds it as a plain `let session = DictationSessionModel()` — deliberately NOT `@Published`, because publishing the reference would forward every inner change straight back to `AppEnvironment.objectWillChange` and restore the exact 50 Hz invalidation this split removes. The coordinator's snapshot handler writes `self?.session.apply(snapshot)` instead of `self?.dictation = snapshot`, and the seven internal readers (`shutdown()`'s live-session check, `toggleDictation()`, all three `performMainHotkeyPress()` branches, `handleTranslationHotkeyPress()`, `handleEscape()`) read `session.phase.isActive`. Dictation behaviour is unchanged and no consumer had to be re-pointed: the capsule/HUD never read `environment.dictation` in the first place — `DictationCoordinator.publish()` already drives it directly through `capsule.update(_:)` / `capsule.updateAudioLevel(_:sessionID:)` into `CapsuleViewModel` / `CapsuleWaveformModel`, which are their own `ObservableObject`s — so live level and live partial text keep their existing responsiveness on their existing path. No low-frequency phase mirror was added to `AppEnvironment` either: grep confirms no panel view reads the phase (button enablement keys off `isReady`, and session failures already arrive on the published `lastSessionError` written by the coarse `recordSessionFailure`), so a mirror would be dead code; the two coarse follow-ups in the snapshot handler (`escapeHotkey.setSwallowArmed`, `recordSessionFailure`) stay where they are because they only act on real phase/session transitions. `AppEnvironment.swift` stays under the 1200-line lint threshold and no new lint warning category appears in any touched file. The new regression `testDictationLevelUpdatesDoNotNotifyEnvironmentObservers` pins the separation structurally rather than by sampling a frame rate: it subscribes counters to both `environment.objectWillChange` and `environment.session.objectWillChange`, replays a full second of the real stream (50 whole snapshots with a moving level and a growing partial, exactly what the coordinator publishes), and asserts the session publisher fired once per frame — the live UI must not lose updates — while the environment publisher fired exactly zero times, which fails on the pre-fix code where every frame notified it. A control at the end writes low-frequency state through the real `reportStartupFailure` writer and asserts the environment publisher does fire there, so the zero is the split at work and not a dead publisher. Manual verification (the audit lists this item as Instruments-only): open the control panel on the History pane, add a temporary `print("HistoryView.body")` at the top of `HistoryView.body` (or attach Instruments' SwiftUI template and record the View Body track), start dictation with the hotkey and speak for several seconds — post-fix the panel body is not re-evaluated per frame (no per-frame prints, no periodic body spikes) while the capsule still shows live level and live partial text; pre-fix the same run prints and spikes roughly fifty times a second (audit P2-6).
- A failed startup no longer masquerades as a working app, and quitting no longer throws away work that was still in flight. `AppEnvironment.initialize()` ran `isReady = true` on BOTH its success tail and its `catch` tail, so an init that threw anywhere along the way — `AppPaths.prepareApplicationSupport()` against a non-writable container, `HistoryRepository()` failing to open or migrate the SQLite file, the initial `reloadHistory()` / `dictionary()` query — left `coordinator` nil while the app advertised itself as fully ready: the control panel rendered its complete live UI, the menu-bar item and the global hotkey both silently hit `guard let coordinator else { return }`, and the user got neither an explanation nor any recovery short of relaunching. A new `@Published private(set) var degradedReason: String?` now carries the failure text, and the `catch` tail routes through a new internal `reportInitializationFailure(_:)` that keeps writing the fatal `startupError` channel (so the existing P2-7 alert and onboarding banner still fire) while leaving `isReady = false` — which, because P2-13's guards in `toggleDictation()`, `recoverSystemIntegrations()`, and `prepareForSleep()` already key off `isReady`, automatically disarms every lifecycle handler in the degraded state instead of letting them run against a nil coordinator; the success tail clears `degradedReason` before flipping `isReady`. Recovery is a real retry rather than a relaunch: the bootstrap attempt from `init(bootstrap:)` and the new `retryInitialize()` now both funnel through one private `startInitialization()` launch point that owns an `isInitializing` re-entrancy flag (a second Retry click collapses onto the in-flight attempt) plus an `initializeAttemptCount` seam, and `retryInitialize()` clears `degradedReason` and the stale fatal banner before re-running the identical initialization path. `ControlPanelView`'s `!isReady` branch — which would otherwise now spin its `ProgressView` forever — renders a new `degradedStartupPane` with the reason and a prominent Retry button whenever `degradedReason` is set, reusing the existing `common.error` key plus one new generic `common.retry` key added to all three of `en`/`zh-Hans`/`zh-Hant` so tri-locale key parity holds. The second half of the item is the quit path: `shutdown()` tore everything down without flushing in-flight work, so a Cmd+Q during a recording went straight to `coordinator.shutdown()`, which cancels the frame task, resets the state machine, and drops the retained PCM — the sentence being spoken vanished with no insertion and no history row — and a Cmd+Q inside the ~1.1 s clipboard-restore window killed the delayed restore `Task` outright, permanently leaving the user's real clipboard replaced by the dictated transcript. `shutdown()` now, immediately after the P3-5 `settingsRepository.flush()`, gives a live session (`dictation.phase.isActive`) the genuine `stop()` path — finalize, insert, history write — and flushes the clipboard after it, because it is `stop()`'s insertion that registers the pending restore. Both additions are hard-bounded: the stop is raced against a 3 s watchdog by a new `AppEnvironment.awaitStopWithTimeout(_:timeout:)` that copies the claim-gate + `NSLock` + `withCheckedContinuation` shape of `DictationCoordinator`'s P2-2 `awaitDrainWithTimeout` (unreachable from this file because it lives in a fileprivate extension there) so the first winner resumes the continuation even when the loser ignores cancellation, and the new `TextInsertionService.flushPendingRestore()` is fully synchronous — it cancels the timer and calls the same guarded `restore(_:ifUnchanged:expectedText:pasteboard:)`, which still refuses to touch a clipboard the user has overwritten since. No unbounded `await` is added anywhere in `shutdown()`, and neither addition captures `self` strongly, so P2-21's `testShutdownCancelsFireAndForgetTasks` deallocation invariant is preserved (under `bootstrap: false` there is no coordinator and no pending restore, so both new steps are no-ops there). The new regression `testFailedInitReportsDegradedAndAllowsRetry` seeds the degraded state through the real production writer `reportInitializationFailure` (same rationale as P2-7's internal-not-private `reportStartupFailure`), asserts `isReady == false` with both `degradedReason` and `startupError` populated, asserts the P2-13 invocation counter stays at zero while degraded, then asserts `retryInitialize()` clears the reason and the stale banner, bumps `initializeAttemptCount` (proof the retry genuinely re-attempts instead of only clearing the banner), and that an immediate second call does not stack a competing attempt (audit P2-14).
- Recoverable runtime failures no longer erase — or get erased by — a genuine fatal startup error: `AppEnvironment.startupError` was the app's only error channel, so a transient settings-save failure, a history query error, a dictionary-save error, a launch-at-login write failure, or a CGEventTap re-registration error all overwrote the diagnostic from a failed `initialize()` (and, in the other direction, a persistent startup banner meant later transient failures were invisible because the slot was already occupied). A second `@Published private(set) var operationError: String?` channel now carries transient failures while `startupError` is reserved for genuine fatal init failures: `startupError` has exactly two writers, both through a new `reportStartupFailure(_:)` — the corrupted-settings-store branch in `init()` and the `initialize()` catch — and all eleven previously-direct transient assignment sites (`saveSettings`, `refreshHistory`, `loadMoreHistory`, `clearHistory`, `deleteTranscription`, `restoreTranscription`, `saveDictionary`, `applySystemSettings`'s launch-at-login write, `updateHotkeyRegistrations`, `updateTranslationHotkey`, `updateEscapeHotkey`) are rerouted through the existing public `report(_:)` reporter, which now writes `operationError`. `ControlPanelView` gains a minimal bottom-overlay toast presenting `operationError` with a 5 s auto-dismiss via `.task(id:)` (byte-for-byte the same shape as the proven `HistoryView` search debounce, so it is safe under Swift 6 `complete` concurrency), a close button reusing the P3-2 `SettingsControlMetrics.minIconHitTarget` floor and the existing `common.close` key (no new localization keys, so the tri-locale key-parity test is unaffected), and an `.overlay` attached to the root `Group` so onboarding also surfaces transient errors. The existing `startupError` presentations (the `ControlPanelView` alert and the `OnboardingView` red banner) plus `dismissStartupError()` are untouched; a matching `dismissOperationError()` is added. Deliberately NOT an `ErrorCenter` abstraction with categories, severities, and routing — two fields and two presentations is the whole requirement. `testOperationErrorDoesNotOverwriteStartupError` seeds a known fatal message through the real `reportStartupFailure` writer, triggers a transient failure, and asserts `startupError` is unchanged while `operationError` holds the new message (audit P2-7).
- A transcript dictated into a password manager, banking app, or any other sensitive application is no longer persisted or uploaded once the user allows insertion into it: the sensitive-app rule was re-derived independently at three call sites with three different formulas — `TextInsertionService.insert` (`protectionEnabled && blockInsertion && isSensitive`), `DictationCoordinator.stop` (the same triple, duplicated inline), and `ReasoningService.shouldCallModel` (`isSensitive && !allowSensitiveAppCloudReasoning`, ignoring the master switch entirely) — while the history write and the debug log consulted nothing at all. History and clipboard were protected only as a side effect of the insertion gate throwing first, so the moment a user turned `sensitiveAppBlockInsertion` off (a supported policy: "protect sensitive apps, but let me dictate into 1Password's notes field") the dictated password flowed straight into the SQLite history database in clear text with no gate anywhere in its path. One new `SensitivityGate` value type in `TextInsertionService.swift` now owns the decision: it is constructed once per session from the captured target plus the active settings, exposes `isProtectedSession` (the frontmost app matched the sensitive list AND the master `sensitiveAppProtectionEnabled` switch is on), and derives all three sink answers from that single flag — `blocksInsertion` (adds the `sensitiveAppBlockInsertion` policy, semantics identical to the pre-fix insertion gate), `blocksPersistence` (history rows and any transcript-bearing log metadata, deliberately with no per-policy opt-out because keeping a password field on disk is never intended), and `blocksCloudReasoning` (adds the `allowSensitiveAppCloudReasoning` opt-in). `DictationCoordinator` stores the gate in a new `sensitivity` property assigned right after `insertion.captureTarget()` in `start()` and reset to `.inactive` alongside `target = nil` in both `shutdown()` and `resetIfCurrent()`; its `stop()` insertion pre-gate now reads `sensitivity.blocksInsertion`, and the `history.save(text:rawText:)` call is wrapped in `if !sensitivity.blocksPersistence`. `TextInsertionService.insert` and `ReasoningService.shouldCallModel` both consult the same type instead of their own copies, so a sensitive session skips the cloud round-trip and inserts the raw transcript, while the local half of `ReasoningService.process` (vocabulary replacement rules, NEW-6) still runs so offline text processing is not lost. The debug-log sink is closed from the other direction: no call site ever put transcript text into log metadata and none is added, and the "Dictation session started" entry now carries a `sensitiveApp: "true"` marker so a gated session is auditable from the log without the transcript ever appearing in it. One intentional semantic change comes with the centralisation: cloud reasoning now honours the master protection switch like every other sink, so turning "protect sensitive apps" off no longer leaves the cloud path blocked while insertion, history, and logging are open — the master switch governs all four sinks uniformly, matching the documented settings hierarchy (master switch + two policy toggles). The new regression `testSensitiveGateHonouredAcrossAllSinks` runs four full coordinator sessions against a pinned captured target (a new DEBUG-only `TextInsertionService.capturedTargetOverride` seam, needed because the frontmost app during a test run is arbitrary — which is exactly why the existing coordinator harness had to disable sensitive-app protection wholesale) plus a stubbed reasoning `URLSession` that counts every round-trip: with a 1Password target, protection on and `blockInsertion` off, the session still completes but history must be empty (the assertion that fails pre-fix), zero reasoning requests must have been issued, and the log must contain the `sensitiveApp` marker and not the transcript; with `blockInsertion` on, the pre-existing `blockedSensitiveApplication` failure and empty history are pinned unchanged; with a TextEdit target the transcript must land in history with both `text` and `rawText` and the log must not carry the marker; and a fourth run proves the cloud sink is genuinely reachable for a non-sensitive app (exactly one POST to `/v1/chat/completions`), so the gate is a decision rather than a blanket block (audit P2-10).
- CoreAudio's realtime render tap no longer allocates ten `AVAudioPCMBuffer` instances while holding `AudioConverterBox.lock` on the first buffer of every session, and no longer holds a Foundation-backed `NSLock` across the render path: `AudioCaptureService.startEngineSession(...)` now calls a new `AudioConverterBox.prewarm(for:)` immediately after constructing the converter and before `installTap`/`engine.prepare()`/`engine.start()`, so the pool of 10 reusable buffers (capacity `max(4_096, sampleRate/10)` frames, mirroring the sizing formula in the reactive branch of `process(_:)`) is populated on `engineQueue` off the audio thread — the first tap callback arriving on CoreAudio's realtime queue therefore pops from a pre-populated pool instead of hitting the previous `poolFormat == nil → availableBuffers = (0..<10).compactMap { AVAudioPCMBuffer(...) }` allocation under lock. `AudioConverterBox.lock` also switches from `NSLock` to a heap-allocated `os_unfair_lock` (`UnsafeMutablePointer<os_unfair_lock>` allocated in the property initializer, freed in a new `deinit`; every acquire/release pair here happens within one thread's stack frame so the "same thread must unlock" contract holds); every existing lock site (`process(_:)`, `drain()`, `finish()`, `reportDiagnostics()`, the copy-failure retire path) is mechanically rewritten to `os_unfair_lock_lock`/`os_unfair_lock_unlock` plus a private `withLock<T>(_:)` helper. Backpressure on consumer lag was already in place through the fixed pool cap (10 buffers) and the existing `droppedFrames` counter surfaced via `onDiagnostics` — this file uses direct `onFrame`/`onLevel` callbacks, not `AsyncStream`, so the audit's "AsyncStream(.unbounded)" concern does not apply here (that usage lives in `DictationCoordinator`, addressed by P2-1). A new private `_allocationsUnderLock` counter is incremented only inside the reactive re-allocation branch of `process(_:)` (retained as a fallback for genuine mid-session format changes covered by A2/A3) and exposed read-only through a `withLock`-protected `allocationsUnderLock` computed property so tests can observe it after `finish()` without racing the drain queue. The new regression `testBufferPoolPrewarmedNoAllocUnderLock` pins both branches of the seam: a non-prewarmed box's first buffer must bump the counter to 1 (positive control proving the seam fires), and a prewarmed box driven through 20 same-format render calls must keep the counter at 0. The pre-existing `testConverterPoolRebuildsOnMidSessionFormatChangeWithoutDroppingAudio` still passes unchanged because the reactive fallback branch retains identical rebuild semantics (audit P2-20).
- Menu-bar "Toggle Dictation" clicks, `NSApplication.didBecomeActiveNotification`, `NSWorkspace.willSleepNotification`, and `NSWorkspace.didWakeNotification` observers registered inside `AppEnvironment.init()` fire on the main actor before the async `initialize()` task finishes wiring the `DictationCoordinator`, the `hotkey.onPress`/`onRelease` closures, and the explicit `translationHotkey/escapeHotkey.setSwallowArmed(false)` resets (`HotkeyService.swallowArmed` defaults to `true` per its initial declaration). Prior to this fix, a notification arriving during that window would run through the handler bodies against a half-initialised environment: `recoverSystemIntegrations()` would mutate `microphones` and drive `refreshPermissions() -> updateHotkeyRegistrations()`, potentially starting the CGEventTap hotkeys with `swallowArmed = true` and no callback wired (swallowing user keystrokes silently), and `prepareForSleep()` / `toggleDictation()` would attempt to tear down / toggle a session against a nil coordinator. Every top-level lifecycle-observer handler now guards on `AppEnvironment.isReady` and short-circuits when the environment has not yet reached the tail of `initialize()`: `toggleDictation()`, `recoverSystemIntegrations()`, and `prepareForSleep()` each early-return on `guard isReady else { return }` so a pre-init event mutates no state, starts no hotkey tap, and awaits no missing coordinator; `initialize()`'s success and failure paths remain the sole assignors of `isReady = true`. A new `AppEnvironment.init(bootstrap:autoMarkReady:)` parameter (default `true`, preserving today's `bootstrap: false` semantics for `testEnvironmentStartsReady` / `testShutdownCancelsFireAndForgetTasks`) lets the regression test hold the environment at `isReady = false`, and a `recoverSystemIntegrationsInvocationCount` test seam (incremented only after the guard passes) makes the assertion deterministic regardless of the host's audio devices or granted permissions. The new regression `testActivationBeforeInitializeDoesNotArmSwallowing` constructs an `AppEnvironment(bootstrap: false, autoMarkReady: false)`, invokes `recoverSystemIntegrations()` directly (the concrete pre-init activation event the audit calls out), and asserts (a) `isReady` stays `false`, (b) the invocation counter stays `0` (proof the guard short-circuited before any body code ran), (c) `microphones` remains its default empty array, and (d) all three hotkey services remain not-running so no CGEventTap with the default `swallowArmed = true` was ever installed (audit P2-13).
- Vocabulary rules configured in `VocabularyRulesView` (`terminologyProfile.avoidedTerms` and `terminologyProfile.replacementRules`) no longer silently do nothing: repo-wide grep confirmed neither field had a single consumer outside `AppSettings.normalize()`, so a user who filled in "avoid these words" or "replace X with Y" saw the UI accept and persist the entries and then observed zero effect on any transcript. `ReasoningService.systemPrompt(settings:)` now emits an "Avoid using these terms in the output; substitute a natural alternative when the meaning allows: …" clause immediately after the existing preferred-terms clause whenever `avoidedTerms` is non-empty, so the list reaches every reasoning provider (OpenAI-compatible / Anthropic / Gemini / Groq / Bailian / custom) as a soft system-prompt constraint via the same `prompt(transcript:settings:)` composition path all providers share. `ReasoningService.process(_:settings:target:)` also runs the final trimmed text — whether it came from the LLM or from the reasoning-disabled passthrough branch — through a new `ReasoningService.applyReplacementRules(_:rules:)` static helper that performs case-insensitive literal substring replacements, so `useReasoningModel == false` users still get their replacement dictionary applied (the previous behavior — reasoning off → rules ignored — is exactly the false promise this fixes). The helper sorts keys by descending length with a lexicographic tie-break so overlapping rules replace the more specific match deterministically, trusts `AppSettings.normalize()`'s existing guarantee that keys/values are trimmed and non-empty, and is a no-op when the dictionary is empty so users who never configured rules see zero behavior change. The audit-required regression `testReplacementRulesAreAppliedToFinalTranscript` seeds a `hello → hi` rule with reasoning disabled and asserts input `"hello world"` returns `"hi world"` — the exact scenario NEW-6 called out — and `testAvoidedTermsAreIncludedInReasoningPrompt` asserts both the terms and the word "Avoid" land in the prompt string returned by the static seam. The prior `testLegacyReplacementRulesDoNotModifyTranscriptWhenCleanupIsDisabled` — which locked in the pre-fix false-promise behavior — is replaced by `testReplacementRulesAreAppliedToFinalTranscript` above, and the pre-existing `testReasoningPromptIncludesDictionaryTranslationAndCustomInstructions` had its `XCTAssertFalse(prompt.contains("legacy avoided term"))` inverted to `XCTAssertTrue` so it now pins the new "avoided-terms reach the prompt" contract while its `XCTAssertFalse(prompt.contains("嘴替 -> Mouthpiece"))` clause is retained to prove replacement-rule notation stays out of the LLM prompt (rules run as POST-processing, not as an LLM instruction) (audit NEW-6).
- Whisper model downloads can no longer delete an existing good model on their way to failing: `LocalModelInstallationService.installWhisper` used to run `try? fileManager.removeItem(at: destination); try fileManager.moveItem(at: temporary, to: destination)` after only a size heuristic + ggml magic check, so a truncated download or a partial cross-volume `moveItem` that failed after the pre-emptive `removeItem` left the user with no model at all — and the temp file was never re-hashed against a pinned checksum, so a CDN-corrupted payload that happened to have the right ggml magic slipped through. The install path now funnels through a new `nonisolated static LocalModelInstallationService.atomicallyReplaceItem(at:withItemAt:expectedSHA256:fileManager:)` helper: when `expectedSHA256` is non-nil the helper streams SHA-256 via a new `streamingSHA256(of:)` that reads the file in 1 MiB chunks through `FileHandle.read(upToCount:)` into an incremental CryptoKit `SHA256` hasher (a multi-GB whisper model is therefore never materialised in memory) and throws a new `ModelInstallationError.checksumMismatch(expected:actual:)` on divergence; the swap itself uses `FileManager.replaceItemAt`, which keeps the pre-existing file present until the rename lands so a failed swap leaves the good model untouched. The temp file is unlinked in a `defer` guarded by a `tempConsumed` flag on every error path (mismatch, replaceItemAt throw, cancellation) so `NSTemporaryDirectory()` no longer accumulates half-downloads. Whisper passes `expectedSHA256: nil` for now because no descriptor pins a hash today — the audit's R3 note observes that huggingface_hub already integrity-checks its snapshots and pinning is defence-in-depth, so wiring the seam without shipping a pin still buys the atomicity win (the pre-existing model survives every non-happy path) and lets a future descriptor field turn on hash-pinning by threading a single string through. The regression `testTruncatedDownloadRejectedExistingModelSurvives` seeds `Data("existing".utf8)` at the destination + `Data("truncated".utf8)` at a temp path, calls the helper with a syntactically valid but non-matching `String(repeating: "0", count: 64)` pin, asserts the `checksumMismatch` throw, asserts the destination bytes are still `"existing"` (the audit's core requirement), asserts the temp file is unlinked, then re-runs the helper with a CryptoKit `SHA256.hash(data:)`-derived hash of the truncated bytes and asserts the destination is now `"truncated"` and the temp is again gone — the positive-case hash is computed with the one-shot API rather than the service's own `streamingSHA256` so a bug in the streaming implementation cannot pass by hashing itself (audit P2-12).
- Quitting Mouthpiece no longer leaks the whole `AppEnvironment` (and its transitively held audio engine, permission service, hotkey taps, capsule window, logger, and modelInstaller) whenever a fire-and-forget public method has a `Task { ... }` still queued: nine sites in `AppEnvironment` — `refreshHistory`, `loadMoreHistory`, `clearHistory`, `deleteTranscription`, `restoreTranscription`, `requestMicrophonePermission`, `refreshLocalModelStatus`, `stopDictation`, and `handleEscape`'s debug-log write — used to spawn a bare `Task { ... }` closure that implicitly captured `self` strongly through the awaited `reloadHistory()` call, the `history` / `permissionsService` / `modelInstaller` / `logger` property accesses, and the post-await state mutations (`self.startupError = …`, `self.transcriptions += …`, `self.selectedLocalModelInstalled = installed`). A stalled DB query, a slow TCC prompt, or a chatty model-server FS probe would keep those closures scheduled past `AppEnvironment.shutdown()`, so the environment stayed alive until every queued Task body drained — and every one of those bodies could still mutate a torn-down environment when it eventually ran. Each site now captures either `[weak self]` alone (history load/clear/delete/restore, stopDictation post-await refresh) or `[weak self, <service>]` (`permissionsService` for the microphone prompt, `modelInstaller` for the install probe) so the awaited service work still runs to completion under its own strong reference while the environment itself is held weakly; every post-await state read/write is routed through `self?` or a fresh `guard let self else { return }` so a released environment turns each into a clean no-op. `handleEscape`'s debug-log Task now captures `[logger]` directly to match the sibling translation-hotkey log site — no `self` at all. `DictationCoordinator`'s already-managed `frameTask` and `providerEventTask` are intentionally untouched: those are structured, stored, and cancelled by `shutdown()` under the P2-1 / P2-2 fixes and did not exhibit the pre-fix leak. The new regression `testShutdownCancelsFireAndForgetTasks` proves the invariant end-to-end: it creates an `AppEnvironment(bootstrap: false)`, captures a `weak var` reference to it, fires every one of those public methods (five of which unconditionally spawn a Task even in `bootstrap: false`, the others short-circuit before Task creation), awaits `shutdown()`, and — critically without yielding the MainActor between shutdown and the assertion (yielding would let each queued Task body run to its guard-short-circuit exit and drop the strong self even in the un-fixed baseline, masking the regression) — asserts the weak reference is `nil` at scope exit. Pre-fix, every queued Task held the environment alive at that point and the assertion failed; post-fix, dropping the local `env` deallocates the environment regardless of whether the Task bodies have executed yet (audit P2-21).
- Onboarding no longer dead-ends privacy-conscious users or corporate-managed installs that decline the Accessibility grant: `OnboardingView`'s `.permissions` step used to gate the "Continue" button on `permissionsReady = environment.permissions.microphone && environment.permissions.accessibility`, so anyone who denied Accessibility in the TCC prompt was pinned on that step with no path forward and could neither reach the hotkey/verification steps nor complete onboarding. Microphone remains mandatory — the app cannot capture speech without it — but Accessibility is now optional: a new pure `OnboardingProgress.canAdvancePermissions(microphoneGranted:accessibilityGranted:accessibilitySkipped:)` returns `microphoneGranted && (accessibilityGranted || accessibilitySkipped)`, so the "Continue" button lights up as soon as the microphone is granted regardless of Accessibility. When the microphone is granted but Accessibility is still declined and not yet skipped, the footer surfaces a secondary "Skip this step" button (reuses the existing `onboarding.skipStep` localization already present in `en`/`zh-Hans`/`zh-Hant`) that flips a session-local `@State accessibilitySkipped = true` and falls through to the shared `advance()`, so the same code path handles both "Continue" and "Skip". `canNavigate(to: .hotkey)` / `canNavigate(to: .tryIt)` and the `permissionsContent` "both required" info label now all route through the same `canAdvancePermissions` bridge so the sidebar navigation and the "still gated" hint stay consistent with the actual advance gate — the sidebar `isComplete(.permissions)` checkmark deliberately still keys off `permissionsReady` (both truly granted) so a skip user gets no false checkmark and the missing grant stays visible. The existing `AccessibilityPermissionBanner` in `ControlPanelView` (rendered while `!environment.permissions.accessibility`) is the ongoing user-facing reminder, so a user who skips still sees a persistent prompt to grant Accessibility later — and once they do, `environment.permissions.accessibility` flips true and the `OR` in the gate is satisfied by the granted branch alone, making the session-local skip state moot without any explicit clear. The skip flag is intentionally `@State`, not `@AppStorage`, so it does not persist across launches: a user who quits mid-flow and relaunches lands back on the permissions step with a fresh choice, not a silent auto-skip. `testOnboardingCanAdvanceWhenAccessibilityDeclined` pins every combination of the three inputs through the pure helper: `(mic ✓, acc ✓, skip ✗) → true`, `(mic ✓, acc ✗, skip ✗) → false`, `(mic ✓, acc ✗, skip ✓) → true` (the P3-4 core case), and both `(mic ✗, …, skip ✓) → false` cases so the microphone-mandatory invariant cannot regress (audit P3-4).
- Small icon buttons across the ControlPanel History pane, the Personalization dictionary list, and the Onboarding startup-error banner no longer force pixel-precise pointer targeting: five plain-styled `Button { Image(systemName: ...) }` sites (`HistoryView`'s per-card trash and per-column doc.on.doc copy, `VocabularyRulesView.EditableTermRow`'s pencil/checkmark edit toggle and trash, and `OnboardingView.startupErrorBanner`'s xmark close) each rendered with a bare ~16 pt SF Symbol and no explicit frame, so the actual hit region was ~16×16 pt — well under Apple HIG's 44×44 pt recommended minimum for reliable pointer/touch input. Every one of the five now threads its hit region through a new shared `SettingsControlMetrics.minIconHitTarget: CGFloat = 44` seam applied as `.frame(minWidth: 44, minHeight: 44)` + `.contentShape(Rectangle())` on the Image inside the Button label, so the icon still renders at its intrinsic SF Symbol size while the entire 44×44 pt rectangle around it is hit-testable. The `SecureField` reveal eye/eye.slash button in `ControlPanelComponents.credential` field is intentionally left at its existing `.frame(width: 24, height: 20)` — its parent credential input is a fixed 22 pt-tall pill and enlarging the inline reveal glyph to 44×44 would break the field's compact layout. The `ForEach` half of the P3-2 audit item was already clean at baseline (repo-wide grep finds zero `ForEach(0..<)` or `ForEach(*.indices, ...)` sites; every history/settings list already iterates over `Identifiable` records or `Array(...enumerated())` with an element-value id), so this commit is hit-region-only. The new regression `testIconButtonHitTargetMeetsAppleHIGMinimum` asserts `SettingsControlMetrics.minIconHitTarget >= 44` so any future reduction of the constant fails the test; because every button site threads through the same constant, a single assertion pins the floor for all five sites at once (audit P3-2).
- A single wrong-typed field in the persisted settings blob no longer silently reverts every OTHER preference to defaults on next launch: `SettingsRepository.decodeWithDefaults` computed a defaults-merged JSON dict then called `JSONDecoder().decode(AppSettings.self, from: merged)`, which fails atomically — one stored leaf whose JSON type disagreed with the AppSettings type (e.g. `translationHotkeySuffix` accidentally persisted as a number, an enum rawValue accidentally persisted as a bool) rejected the entire blob, so the repository stored `AppSettings()` as the in-memory value and every unrelated preference (dictation key, cloud provider, terminology profile, translation state, sensitivity gates, …) reset. The decode is now a two-pass strict-then-tolerant sequence backed by a private `DecodeResult` enum. Pass 1 runs the pre-existing merge-with-defaults + strict JSONDecoder path unchanged, so a healthy blob (including forward-compatible old blobs missing new keys) hits `.strict` and behaves exactly as before. Pass 2 runs on strict failure: the same recursive `merge` helper now takes a `tolerateTypeMismatches: Bool` flag that, on the tolerant path, drops every leaf whose stored JSON type disagrees with the default's JSON type (compared via `isSameJSONType`, which uses `CFGetTypeID(_ as CFTypeRef) == CFBooleanGetTypeID()` to separate JSON booleans from JSON numbers since both bridge to `NSNumber`), so the surviving well-typed leaves ride into the second JSONDecoder attempt and only the mismatched fields fall back to `AppSettings()` defaults. Whenever Pass 1 fails — whether Pass 2 recovers or the payload is unsalvageable (non-JSON, JSON array, structurally broken beyond the shape check) — the init archives the original bytes under `native.settings.v1.corrupt.<epoch>` in the same UserDefaults suite (idempotent under same-second collisions: a pre-existing backup at the same second is preserved), so users and support engineers can still inspect the pre-corruption blob after the next `save()` overwrites the primary key. The `.unrecoverable` branch preserves the existing invariants: raw bytes stay at the primary key, `loadFailed = true` still surfaces the UI warning, and the OSLog error line still fires. The corrupt-blob backup path deliberately uses a distinct key so the P3-5 debounce `writeCount` seam still counts only primary-key writes. Two new tests pin the new behaviour: `testSingleBadFieldKeepsOtherFields` seeds a blob with `dictationKey = "LeftCommand"` (valid per `HotkeyDescriptor.isValid` and different from the `"RightCommand"` default so the assertion is not trivially satisfied by the pre-fix full-reset path) alongside `translationHotkeySuffix = 42` (number where String is expected) and asserts `dictationKey` survives, `translationHotkeySuffix` falls back to `TranslationHotkey.defaultSuffix`, `loadFailed` stays false, and exactly one `native.settings.v1.corrupt.*` backup with bytes equal to the original blob is recorded; `testCorruptBlobSurvivesSubsequentSave` seeds true garbage, asserts `loadFailed = true` plus a backup, then calls `save()` + `flush()` and confirms the primary key overwrites cleanly with the new blob while the corrupt-blob backup survives untouched. The existing `testCorruptSettingsSurfaceLoadFailureAndKeepTheBlob` still passes unchanged because non-JSON bytes hit `.unrecoverable` (audit P2-8).
- Dictation HUD, rolling transcript, and control-panel sidebar now honour macOS accessibility preferences instead of playing full-motion, low-contrast animations to every user: previously the capsule crossfade between `contentKind` states (`.easeOut(duration: 0.14)`), the rolling-transcript auto-scroll (`.easeOut(duration: 0.18)`), the sidebar section-select (`.easeOut(duration: 0.16)`), and the sidebar row hover / isSelected transitions all ran unconditionally, and the capsule border stroke stayed 0.8 pt at `Color.primary.opacity(0.15)` — invisible in ambient light for a user who had enabled System Settings → Accessibility → Display → Increase contrast. Every SwiftUI view involved now reads `@Environment(\.accessibilityReduceMotion)` (and, for the visual bumps, `@Environment(\.colorSchemeContrast)`): the capsule content transition routes through a new pure static helper `CapsuleController.contentTransitionAnimation(reduceMotion:)` that returns `nil` when Reduce Motion is on so `.animation(nil, value:)` skips the transaction entirely and returns `.easeOut(duration: 0.14)` otherwise; the rolling-transcript `withAnimation` and both sidebar `withAnimation` sites do the same `reduceMotion ? nil : .easeOut(...)` guard. Under Increase Contrast the capsule's border stroke widens from 0.8 pt to 1.6 pt and its `borderTint` gradient roughly doubles both stops' opacity (capped at 1.0) so the outline stays visible over `.thinMaterial`; the control-panel sidebar's selected-row stroke widens from 0.5 pt to 1.4 pt with a matching opacity bump on the accent tint, so the selected section is discernible without relying on the subtle accent gradient background alone. `CapsuleWaveformView.update` already honoured `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (waveform interpolation is snapped to the target when set), and onboarding step transitions are plain `@State` assignments with no `withAnimation` wrapper, so those two sites are already reduce-motion-safe and were intentionally left untouched. The new regression `testReduceMotionDisablesCapsuleContentTransition` pins both branches of the extracted helper (nil for `reduceMotion: true`, non-nil for `false`), so any future re-hardcoding of the animation drops the test. The Increase Contrast stroke/opacity bumps and the sidebar `withAnimation` gates cannot be exercised without live SwiftUI environment injection, so they carry manual verification steps: enable System Settings → Accessibility → Display → Reduce motion and confirm the capsule crossfade between identity/status/transcript/error and the rolling-transcript scroll snap immediately with no ease-out (also verify the sidebar section switch and row hover are instantaneous); enable Increase contrast and confirm the capsule outline visibly thickens and the sidebar's selected row shows a clearly heavier accent-tinted outline (audit P3-1).
- Settings mutations no longer re-encode and re-write the entire settings blob to UserDefaults on every checkbox toggle, slider tick, or text-field keystroke: `SettingsRepository.save()` used to run `JSONEncoder().encode(normalized)` and `defaults.set(data, forKey: "native.settings.v1")` inline on the main actor, so a slider drag firing ~60 save()/s produced 60 full encodes and 60 UserDefaults writes per second — pure wasted work since only the final value matters. `save()` now still normalizes, encodes, and updates the in-memory `cached` state synchronously (consumers reading through `load()` observe the mutation immediately and any encoding error still throws from the same call), but the actual `defaults.set(_:forKey:)` write is deferred behind a `debounceInterval = 250 ms` timer. Every subsequent `save()` cancels the pending timer and reschedules with the latest encoded blob, so a burst of 10, 60, or 600 rapid saves collapses into one UserDefaults write once the drag stops. Because this breaks the "durable after `save()` returns" contract, a new `flush()` method commits any pending write synchronously and is invoked at the top of `AppEnvironment.shutdown()` — before any `Task` cancellation or `await` — so a slider adjustment made moments before Cmd+Q still lands on disk. A test seam `writeCount` exposes the actual number of `defaults.set(...)` invocations so the new `testRapidSaveCoalescesToSingleWrite` can prove 10 rapid saves + flush produce exactly one write matching the last save's state, and `testShutdownFlushesPendingSave` proves shutdown flushes the pending blob and that a second flush is a no-op (audit P3-5).
- VoiceOver users no longer hear silence during the `.preparing`, `.processing`, `.inserting`, and `.cancelled` phases of a dictation session: `CapsuleController.announcementKey(for:)` used to `switch` over `DictationPhase` with a `default: nil` fall-through that only mapped `.recording`, `.stopping`/`.finalizing`, `.completed`, and `.failed` to a localized key, so the four remaining phases (all of which the sighted capsule UI visibly displayed via `statusText`) posted no `NSAccessibility.announcementRequested` at all — a screen-reader user pressing the dictation hotkey heard nothing from mic-warmup through Refining/Inserting, and a mid-recording Escape produced no audible "Cancelled" confirmation. The mapping is now an exhaustive `switch` with no `default`, so every non-`.idle` case returns a non-nil localized key (`.preparing` → `capsule.preparing`, `.processing` → `capsule.polishing`, `.inserting` → `capsule.inserting`, `.cancelled` → the new `capsule.cancelled`, plus the previously-covered phases unchanged) and `.idle` alone stays silent so the announcement is not re-fired when a session ends and the capsule dismisses. `capsule.cancelled` was added to `Native/Resources/{en,zh-Hans,zh-Hant}.lproj/Localizable.strings` as "Cancelled" / "已取消" / "已取消". `DictationPhase` gains a `CaseIterable` conformance (no behaviour change) so the new iteration-based regression test `testEveryNonIdlePhaseHasAnnouncement` can walk `DictationPhase.allCases` and assert every non-`.idle` phase returns a non-nil key that resolves to a non-empty localized string in all three UI languages — any future new `DictationPhase` case that forgets an announcement mapping or a localization now fails that test, and dropping the `default` means the Swift compiler additionally refuses to compile a `switch` that omits the new case. `testCapsuleAnnouncementKeysCoverExactlyTheAnnouncedPhases` was updated in the same pass to pin each specific phase → key pair (audit P3-3).
- Dictation transcripts no longer land in clipboard-manager history (Alfred / Paste / Raycast / Maccy / Pastebot / …): every pasteboard write that carried transcript text used the raw `NSPasteboard.general.clearContents(); setString(text, forType: .string)` pair, and macOS has no first-party "concealed" flag, so a password dictated into a Terminal `sudo` prompt (which falls into the Secure Input keep-in-clipboard path), a dictation kept in the clipboard by the `keepTranscriptionInClipboard` setting, the sub-second paste-then-restore flash, and even a user-initiated "Copy" from the History view all rode into every clipboard manager's long-term store — indistinguishable from any other copied text. The four transcript sinks (`TextInsertionService.copyToClipboard`, `retainTranscriptIfSecureInputActive`, the paste-path clipboard flash, and `HistoryView.copy`) now funnel through a single `NSPasteboard.writeTranscriptText(_:transient:)` extension that stamps every write with the community `org.nspasteboard.ConcealedType` marker (http://nspasteboard.org/), which every mainstream clipboard manager honours as "do not retain in history". The paste-then-restore fast path additionally stamps `org.nspasteboard.TransientType` so managers ignore the sub-second flash entirely rather than merely skipping retention; the Secure-Input keep-in-clipboard case and the "keep transcription in clipboard" setting deliberately do NOT stamp Transient because the user is expected to Cmd-V at their own pace. The helper uses the same `clearContents()` + `NSPasteboardItem` + `writeObjects` shape the existing `restore()` uses, so all types are declared atomically (Apple's `NSPasteboard.setData` requires declared types) and `changeCount` still bumps exactly once per write — the paste/restore ladder's `snapshotForNewPaste` / `restore` invariants around `changeCount` are unchanged. `testTranscriptClipboardWriteIsMarkedConcealed` uses `NSPasteboard.withUniqueName()` so no test writes touch the system clipboard, pins ConcealedType present on both the keep and transient cases, TransientType present only when `transient: true`, and TransientType correctly cleared on the next non-transient write to the same pasteboard so a keep-in-clipboard follow-up does not inherit the previous flash's marker (audit NEW-1).

- Release checksums no longer embed the build machine's absolute paths, and concurrent or retried DMG builds no longer collide on `/Volumes/Mouthpiece <version>`: `scripts/build-native-release.sh` used to run `shasum -a 256 "$ROOT/$OUTPUT/..."`, so the emitted `Mouthpiece-<version>-<arch>.sha256` wrote lines like `<hash>  /Users/runner/work/Mouthpiece/artifacts/Mouthpiece-2.0.11-arm64.dmg`, and a downstream consumer running `shasum -c` from any other directory failed until they reproduced the exact runner path tree. The same script also mounted the DMG at a hard-coded `/Volumes/Mouthpiece $VERSION` off a hard-coded `.build/release/rw-$ARCH.dmg`, so a retry after a leaked mount or two same-arch builds on one runner would step on each other — worse, the script's pre-emptive `hdiutil detach "$MOUNT" 2>/dev/null || true` would happily yank a concurrent build's mount. The checksum step now runs inside a subshell after `cd "$ROOT/$OUTPUT"` and passes bare basenames, so the sha256 file reads `<hash>  Mouthpiece-<version>-<arch>-mac.zip` / `<hash>  Mouthpiece-<version>-<arch>.dmg` and `shasum -c` succeeds from whatever directory the artifacts land in. The DMG step now allocates a per-run `mktemp -d "$ROOT/.build/release/dmg-<arch>.XXXXXX"` workdir for the RW image, HiDPI background rescale, and mountpoint (attached via `-mountpoint`, never `/Volumes/`), and stamps the RW volume with a build-unique volname `Mouthpiece <version> <arch>-$$` so Finder's `tell disk` inside the layout AppleScript cannot alias between two concurrent same-version builds. A new `trap cleanup_dmg EXIT` (registered before the `mktemp` call, with `MOUNT`/`WORK_DIR` initialised empty so the handler is safe under `set -u` even when `mktemp` itself fails) unconditionally runs `hdiutil detach` (falling back to `-force`) and `rm -rf` the workdir on every exit path, so a hung AppleScript or a failed layout can no longer leak a mount into the next run. Right before the final `hdiutil detach` + UDZO convert, `diskutil renameVolume "$MOUNT" "Mouthpiece <version>"` renames the mounted HFS+ label back to the release-facing name, so the shipped DMG still surfaces `Mouthpiece <version>` in Finder when end users mount it and the build-unique suffix stays inside the build. `set -euo pipefail` was already in place at the top of the script (audit P2-19).
- Release CI can no longer ship a Sparkle appcast whose newest entry is not the just-built release: `.github/workflows/release.yml` merges the just-built appcast item into the previous release's feed (keeping up to five newest versions so a yank still has a working update path), but the only post-merge validation was the "Validate artifacts and release notes" step doing `test -s appcast-<arch>.xml`, `grep -q 'sparkle:edSignature='`, and `grep -q '15.0'` per arch — every one of which the previous release's entry alone satisfied, so a broken `generate_appcast` run or a merge that failed to prepend the current build would still pass CI and ship a feed whose newest `<item>` was the prior release. A new "Validate appcast has current release" step runs immediately after the merge and before any downstream step (electron-updater feed, release upload). It parses each per-arch appcast with a small Python `xml.etree.ElementTree` snippet, takes `channel/item[0]` — guaranteed newest because the merge step sorts by `sparkle:version` DESC — and asserts four things about that item: (1) `sparkle:version` (child element or `enclosure/@sparkle:version` attribute) equals the freshly-computed `CURRENT_PROJECT_VERSION` (`major*10000 + minor*100 + patch`, the exact formula `scripts/build-native-release.sh` uses to bake CFBundleVersion into Info.plist); (2) `sparkle:shortVersionString` equals `$VERSION` (the marketing version passed as `MARKETING_VERSION`); (3) `enclosure/@url` contains `$TAG` so the download link is pinned to this tag's release assets rather than a stale one; (4) `enclosure/@sparkle:edSignature` and `sparkle:minimumSystemVersion` are both present and non-empty. Any failure exits non-zero with a message naming the offending file and the missing/mismatched attribute, so a merge or generate regression fails the release job instead of shipping a stale feed. `VERSION`/`TAG` reach the shell via `env:` (not raw `${{ }}` interpolation) and are already regex-validated by `scripts/validate-release-version.sh` in the `prepare` job (audit P2-16).
- IDE builds can no longer diverge silently from CI/release when `project.yml` has been edited without regenerating the pbxproj: `Mouthpiece.xcodeproj/` is generated from `project.yml` via `xcodegen generate` yet is also committed to the repo, so the two sources could drift; the release pipeline always regenerates before shipping, which meant only IDE developers pulling the drifted pbxproj saw a project graph different from CI/release, with no signal beyond a confusing local-vs-CI build difference. `.github/workflows/ci.yml`'s `test` job now runs a new "Verify xcodeproj matches project.yml" step immediately after the existing `xcodegen generate` step and before the test step: `git diff --exit-code -- Mouthpiece.xcodeproj/` fails the workflow if the just-regenerated project differs from the committed one and prints a `::error::` line pointing at running `xcodegen generate` locally and committing the result. The check-only approach intentionally preserves the committed pbxproj — removing it is a bigger decision documented in the audit ledger — and the assertion itself is the regression check (audit P2-15).
- Two `AppSettings` stored properties that were persisted but never read anywhere in the app have been deleted: `cloudBackupEnabled` (implied a nonexistent cloud-backup feature) and `allowSensitiveAppPasteMonitoring` (implied a paste-monitoring opt-in on sensitive apps that was never wired to any consumer). Both were purely declarative — no view, service, or coordinator ever branched on them — so the UI could only have communicated a promise the code did not keep. Removing them shrinks the settings surface to what the app actually honours. Persisted settings blobs on user machines that still carry these keys continue to decode without loss: `SettingsRepository.decodeWithDefaults` uses a plain `JSONDecoder` (no `keyDecodingStrategy`, no custom `init(from:)`), and the synthesized `AppSettings` Codable silently ignores keys with no matching stored property, so the fields just fall away on next load-and-save (audit P3-6).
- History save() no longer runs a self-anti-join on every write: `HistoryRepository.save()` used to fire `DELETE FROM transcriptions WHERE id NOT IN (SELECT id ... ORDER BY timestamp DESC LIMIT ?)` after every single insert, which cost O(N log N) per save as history grew — measurable at even a few thousand rows and wasteful for the 99.9% of saves that produce zero deletions. Prune now runs once per app launch (from `AppEnvironment.initialize()`, which already `await`s `history.prune()` for the delete-count log) and then only once per `pruneEveryNWrites = 32` inserts, so a full day of dictation runs prune a handful of times instead of hundreds. `HistoryRepository` cannot bootstrap the startup prune from its own `init()` because it is an actor and `prune(now:)` is actor-isolated — an unavoidable Swift 6 constraint — so the AppEnvironment call is the canonical entry point. The row-cap DELETE itself is also cleaner: `DELETE ... WHERE id IN (SELECT id ... ORDER BY timestamp DESC, id DESC LIMIT -1 OFFSET ?)` bound to `retentionMaxRows` walks the timestamp index once instead of computing a `NOT IN` anti-join set — retention semantics are identical (skip the newest N in DESC order → delete the older surplus rows, with the same `timestamp DESC, id DESC` tie-breaker). A new `pruneObserver` seam on `HistoryRepository.init(...)` lets `testInsertsBelowThresholdDoNotTriggerPrune` count invocations regardless of whether rows were deleted (orthogonal to the existing `pruneLogger`, which still fires only on non-zero deletions), asserting one prune after an explicit startup call, still one after 31 inserts, and exactly two after the 32nd (audit P2-17).
- Reverted an ineffective keychain hardening claim: `KeychainStore.write` had been setting `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on both the SecItemAdd and SecItemUpdate paths, but this store writes to the macOS legacy file-based keychain, which silently discards that attribute and never returns it — a read-back probe in the signed test host shows `SecItemCopyMatching` handing back only `acct,cdat,class,labl,mdat,svce`, with both `kSecAttrAccessible` and `kSecAttrSynchronizable` absent. The only backend that honors the attribute is the data protection keychain, and `SecItemAdd` with `kSecUseDataProtectionKeychain: true` returns `errSecMissingEntitlement` (-34018) under this app's self-signed identity, because the required `application-identifier`/`keychain-access-groups` entitlement can only be derived from an Apple-issued Team ID (`project.yml` sets `CODE_SIGN_IDENTITY: Mouthpiece Code Signing` with no `DEVELOPMENT_TEAM`). The dead attribute, its `KeychainStore.accessibility` seam, and the regression test `testCredentialAccessibleAttributeIsDeviceOnlyOnAddAndUpdate` (which asserted on an attribute that is never persisted, and so could not pass in any environment) are all removed; credential storage behavior is unchanged from 2.0.10. Device-binding for stored API keys remains an open item gated on signing credentials, tracked as NEW-5 不适用 in the audit ledger (audit NEW-5, 已证伪).
- Release DMG packaging is buildable again after the P2-19 collision fix broke it: moving the mount off `/Volumes` to a per-run mktemp mountpoint made Finder unable to resolve `tell disk "<name>"`, so the layout AppleScript failed with `-1728` ("Can't get disk") on both runners and — correctly, since that step intentionally has no `|| true` fallback — failed the build before any artifact was produced. `-nobrowse` was never the problem (v2.0.10 shipped with it); Finder only resolves disks mounted under `/Volumes`. The image now mounts at `/Volumes/<build-unique volname>`, keeping P2-19's concurrency and retry safety in the volume NAME instead of the path. Two latent bugs in the same block are fixed with it: the build volname was `Mouthpiece <version> <arch>-<pid>`, exactly 27 characters for arm64 with a 4-digit pid and therefore silently truncated by HFS+ at 5 digits (which would have broken `tell disk` intermittently) — it is now the short `Mouthpiece <arch>-<pid>`; and `diskutil renameVolume` relocates the volume to `/Volumes/<final name>`, so the following `hdiutil detach "$MOUNT"` could never have succeeded — detach and the exit trap now both go through the device node captured from `hdiutil attach`. Verified by running the DMG block verbatim against a synthetic staging tree: exit 0, non-empty `.DS_Store` layout gate passed, valid UDZO image produced; shellcheck clean (audit P2-19 follow-up).
- Debug log files can no longer grow without bound: `DebugLogStore.prune()` only ever deletes NON-active files (`if file == fileURL { continue }`), so a menu-bar app running for weeks kept appending to a single active file that the daily prune never rotated — a 4-hour idle session with normal chatter was enough to push it past 4 MB, and there was no upper limit at all. `DebugLogStore` now tracks `bytesWritten` per open handle (seeded from `try handle.seekToEnd()` on open so a warm-start with existing bytes honours the ceiling immediately) and, when the next JSON+newline append would push the total past `maximumFileBytes` (default `4 * 1024 * 1024`), calls a new `rollActiveFileIfNeeded(pendingBytes:now:)` helper that closes the handle, renames the active file to a `debug-<ts>-rolled.log` archive via `uniqueArchiveURL(for:)` (which appends a numeric `-<seq>` suffix on collision so multiple rolls inside the same ISO-8601 second — bursts, tests — cannot clash), and re-invokes `prepareIfNeeded(now:)` to open a fresh active file at the standard `debug-<ts>.log` path. The archive still matches the existing `hasPrefix("debug-") && pathExtension == "log"` prune filter so the 7-day / 20-file retention reaps it with zero policy change, and `setEnabled(false)` resets `bytesWritten` alongside the handle so a re-enabled logger starts clean. Because writes go through the actor, `prepareIfNeeded → rollActiveFileIfNeeded → write → bytesWritten +=` is serialised end-to-end and no writer can interleave a truncation. Additionally, `AppEnvironment.initialize()` no longer aborts startup when the logs directory is transiently unreadable: `try await logger.prune()` becomes `try? await logger.prune()`, matching the pattern used three lines below for history prune — DebugLogStore's own OSLog error line still captures the failure (audit P2-11).
- Sparkle appcast selection no longer Rosetta-locks an x86_64 build on Apple Silicon: `ArchitectureUpdateFeedDelegate.feedURLString` used to branch on `#if arch(arm64)`, a compile-time constant baked into the slice, so an x86_64 build translated by Rosetta 2 on an arm64 host would forever fetch `appcast-x64.xml` and never surface the arm64 update that would migrate the user off the translated slice — silently permanent. The delegate now picks the appcast at runtime through a pure seam `feedURLString(hostSupportsARM64:)` composed with `hostSupportsARM64()`, which reads two independent `sysctlbyname` signals: `hw.optional.arm64 == 1` (the CPU is arm64-capable, true for both native and translated processes) OR `sysctl.proc_translated == 1` (this process is being translated by Rosetta 2, only possible on an arm64 host). Either signal is sufficient, so a stranded x86_64 binary still routes to the arm64 appcast and can offer the user a native update; on real Intel Macs both queries return 0/ENOENT and the x64 appcast is served unchanged. The base URL and the arch → filename mapping (`appcast-<arch>.xml`) are preserved verbatim, and the new `testUpdateFeedURLPrefersARM64WhenHostSupports` pins both branches of the seam to their published feed URLs (audit P2-9).
- Realtime finalize now shares one canonical timeout budget without regressing Bailian's fallback-ladder throw: each of the five WebSocket providers had its own hard-coded `.seconds(5)` inside `finish()` (magic constant copied per file, prone to drifting from the URLSession default of ~60 s that would have applied had the wait been elided). A single shared `RealtimeSocketSession.defaultFinalizeTimeoutSeconds = 5` now defines the canonical budget and `RealtimeSocketSession.logFinalizeTimeout(provider:)` emits one uniform `com.mouthpiece.app / realtime` warning on fall-through. Behavioural policy is preserved per provider: (a) all five providers reuse the shared 5 s constant; (b) Bailian is realtime-only, so an unfinished `task-finished` still THROWS `BailianRealtimeError.timedOut` — that throw is what routes finalize into `DictationCoordinator.stop`'s P1-2/NEW-7 recovery ladder (batch/local fallback with a real error), and dropping to best-partial there would silently swallow the tail for a provider that has no batch endpoint of its own; (c) the other four providers (Volcengine / Deepgram / AssemblyAI / Soniox) are unchanged in behaviour — they already fell through to best-partial (`liveText` / `joinedTranscript()`) pre-audit, they just now share the constant plus the warning. Provider-specific semantics are also preserved: Soniox's `<end>`/`<fin>` filtering (P1-13) still authoritatively defines what "finalized" means, Bailian still flushes its residual `pendingAudio` chunk before sending `finish-task`, Deepgram's post-`CloseStream` server-close is still classified as benign, Volcengine still sends its `isLast: true` audio frame, and AssemblyAI still emits `Terminate` (audit P2-4).

- Realtime cold-start no longer silently deletes the beginning of a slow-connecting session: `RealtimePendingAudioBuffer` capped queued PCM at 3 s (`3 * 16_000 * 2` bytes) with a `while byteCount > cap { removeFirst() }` drop-oldest policy while every WebSocket provider allowed up to 15 s to confirm the connection via `RealtimeSocketSession.waitForCondition(timeout: .seconds(15), ...)` (Bailian's `createTask` allowed 30 s for `task-started`), so any connect exceeding 3 s silently truncated the leading audio and returned a mangled transcript with no fallback signal — the coordinator's degrade-vs-fail policy never fired because the frame path never threw. The shared cap is now tied to the confirmation timeout through `RealtimeSocketSession.pendingAudioCapacityBytes(confirmationTimeoutSeconds:sampleRate:bytesPerSample:)` (default 15 s → 480 000 bytes for Volcengine/Deepgram/AssemblyAI/Soniox; Bailian passes 30 s explicitly for its 30 s task-started deadline). When the cap IS exceeded — indicating a truly stuck connect — the buffer still drops the oldest bytes so RAM stays bounded, but a new `leadingAudioDropped` flag flips to `true` and survives `detachAll()` so a successful late connect + flush cannot mask the earlier truncation. Every provider's `finish()` reads that flag as the first step: if set, it cancels the session and throws `RealtimePendingAudioError.leadingAudioDropped`, which `DictationCoordinator.stop`'s finalize catch remembers as `realtimeError` — the empty-transcript recovery ladder then falls back to batch/local transcription using the fully retained PCM (`pcm.append(frame)` runs before every `provider.send`, so `recordedPCM = speechGate.trimmed(pcm)` still holds every frame the mic delivered). No other behaviour changes: successful connects still flush all queued frames in arrival order via the existing `flushPendingAudio` sites, the running-send path is untouched, and `cancel()`/`closeSocket()`/`resetTranscript()` clear both the buffer and the flag so a re-armed session starts clean (audit P2-3).
- `DictationCoordinator.stop()` no longer parks the session in `.stopping` forever when a stream teardown hangs: the P2-1 drain sequence awaited `frameTask?.value` and then `providerEventTask?.value` (via `drainProviderEventStream`) unbounded, so a hung audio engine that never released the frame stream continuation or a dead provider socket whose event stream never finished wedged the coordinator with no user recourse except Escape. A new `awaitDrainWithTimeout(frame:event:timeout:)` helper races the combined drain against a 3 s watchdog using the same claim-gate/`withCheckedContinuation` shape as `finishWithTimeout` — a `withTaskGroup` variant would still block on the group's implicit join when the awaited drain Tasks ignore cancellation, whereas the claim-gate resumes the caller on the first winner. On timeout it best-effort cancels both consumer Tasks (AsyncStream `for await` exits on cancellation) and lets `stop()` fall through to finalize with whatever PCM/partial text is available, emitting one warning log; the retained partial still reaches history — losing an in-flight tail beats losing the whole recording. The frame stream drain, provider event drain, and every existing session-ID/phase guard downstream of the drain are untouched (audit P2-2).
- Realtime provider events can no longer be applied out of emit order: `DictationCoordinator` used to wire the provider's event callback as `Task { await self?.handle(event, sessionID) }`, spawning one unstructured Task per event, so a late `.partial` (or a woken race winner) could overwrite a preceding `.final` on the state machine's `partialText` and land the wrong transcript at stop time. The callback now yields every event into a single `AsyncStream<RealtimeTranscriptionEvent>` per session, drained by one consumer task that awaits `handle(event:)` sequentially — the same single-consumer shape the frame path already uses. Teardown mirrors the frame stream: `stop()` finishes the continuation and awaits the consumer before snapshotting `partialText`, and `shutdown()`/`resetIfCurrent()` cancel the task and finish the continuation so no stray consumer survives. Existing session-ID/phase guards, the degrade-vs-fail policy, and provider cancellation are untouched (audit P2-1).

- CI can no longer stay green while the coordinator's 14 high-value tests silently XCTSkip: `DictationCoordinatorTests.makeHarness` and `PersistenceTests.testKeychainStoreRoundTripOverwriteAndDelete` both hit a real `KeychainStore`, whose `SecItemAdd` triggers a SecurityAgent ACL prompt on fresh test-host signatures — on locked-screen dev boxes and on any CI runner the prompt is impossible so the write threw `errSecInteractionNotAllowed`, the harness raised `XCTSkip`, and `xcodebuild test` reported success with "Skipped" invisible to the workflow. Two independent gains combine here: the coordinator harness no longer touches the keychain (a new `CredentialStore` protocol widens `DictationCoordinator.init(keychain:)` and `ReasoningService.init(keychain:)` from the concrete `KeychainStore` to `any CredentialStore`; a test-only `InMemoryCredentialStore` actor is seeded with the bailian test key so the whole class now executes without a prompt, and `AppEnvironment` still passes the production `KeychainStore` singleton so the release wire-up is identical); and `.github/workflows/ci.yml` gains a "Gate on test execution counts" step that parses `xcrun xcresulttool get test-results summary --path .build/test-results/Mouthpiece.xcresult` with python + `sys.exit(1)` and fails the workflow if `failedTests > 0`, `skippedTests > 0`, or `totalTestCount < 128` (the current floor, sized just below today's baseline so accidentally dropping a whole test class fails CI instead of shipping). `PersistenceTests.testKeychainStoreRoundTripOverwriteAndDelete` is intentionally untouched — it is the real keychain-semantics regression — and the new gate is what turns a keychain-unavailable CI runner into a loud failure instead of a silent skip (audit P1-15).
- Release DMGs can no longer ship a signed `Mouthpiece.app` that silently drops the bundled model-server runtimes or MediaRemote adapter: `scripts/verify-native-artifact.sh` previously only inspected the main executable, one entitlement, `LSMinimumSystemVersion`, and its own arch, so a broken `build-native-release.sh` copy step would still pass the 5-second launch smoke (which never exercises dictation or media pause) and reach users. The verifier now asserts `Contents/Resources/Binaries/whisper/whisper-server-darwin-<arch>`, `.../parakeet/sherpa-onnx-ws-darwin-<arch>`, and `.../mediaremote/MediaRemoteAdapter.framework` exist inside the mounted DMG and each Mach-O matches the release architecture via `lipo -verify_arch`; any missing file or arch mismatch fails the release build (audit P1-14).
- Crashing or Force-Quitting Mouthpiece no longer leaks a multi-GB local model-server subprocess: `LocalModelRuntime.stopAll()` only runs through `AppEnvironment.shutdown → DictationCoordinator.shutdown → stopAll`, so a hard exit reparented the whisper/parakeet/qwen child to launchd, and the next app launch's `availablePort(in:)` merely picked the next free port and spawned a SECOND server (multiplied per crashed launch). `LocalModelRuntime.launch(...)` now atomically writes an OS-visible runtime-state record `AppPaths.applicationSupportDirectory/runtime/<kind>-<childPID>.json` containing `{ownerPID, port, executable, model, launchedAt}` after every successful `Process.run()`, and the graceful `stop(_:)` path deletes that record. On the first `ensureWhisper/ensureParakeet/ensureQwen` call each launch, a new `nonisolated static reapOrphanServers(directory:fileManager:)` scans every `*.json` under the runtime directory: if the record's `ownerPID` returns ESRCH from `kill(_, 0)` the previous Mouthpiece is definitely gone, the recorded child PID is verified with `proc_pidpath` against the recorded executable (to survive PID reuse), the child is stopped with SIGTERM → 500 ms grace → SIGKILL, and the record is removed. When `proc_pidpath` returns a different executable the record is deleted without signalling. A `didReapOrphans` guard makes the first ensure*() call for any provider reap orphans left by every other kind, so a whisper spawn also reaps parakeet/qwen. `availablePort(in:)` is untouched — the reaper is what closes the orphan window (audit P1-10).
- Local model-server binaries (`whisper-server`, `sherpa-onnx-ws`, `mlx-qwen3-asr`) can no longer be preempted by an impostor dropped into a user-writable directory. `LocalModelRuntime.binaryURL(_:)` used to enumerate `AppPaths.applicationSupportDirectory/.../bin`, the working directory's `resources/bin`, and — worst of all — `legacyQwenASRRuntimeDirectory`/`qwenASRRuntimeDirectory` for qwen (inserted at index 0 BEFORE `Bundle.main`), selecting the first `isExecutableFile` hit with no signature check. Combined with the Microphone/Accessibility TCC grants and `com.apple.security.cs.disable-library-validation`, a local attacker with prior write access to those paths inherited both grants (TCC laundering; defence-in-depth, not remote RCE). The new `LocalModelRuntime.binaryCandidateURLs(for:)` always emits `Bundle.main.resourceURL` candidates first, and every user-writable path (Application Support, CWD, both qwen runtime caches) is compiled out in release builds via `#if DEBUG`. `launch(...)` also runs a pre-launch containment gate — `isBinaryInsideMainBundle(_:)` — that refuses any resolved executable outside `Bundle.main.resourceURL` with `LocalModelRuntimeError.binaryVerificationFailed(URL)`. Structural path containment is the decisive gain (the app is self-signed and unnotarised, so there is no stable Team ID to pin a `SecStaticCode` requirement to, and the model-server binaries have their own cdhash distinct from the host); a DEBUG test seam (`testForceBundleOnly`) lets the new regression test assert the exact release-mode shape (audit P1-9).
- Soniox realtime transcripts no longer leak the raw `<end>` control marker or inject an ASCII space between CJK glyphs: with `enable_endpoint_detection` on, Soniox emits both `<end>` and `<fin>` as literal tokens on the raw WebSocket (their soniox-js SDK filters `{<end>, <fin>}`), but `SonioxRealtimeProvider` only compared against `<fin>` in one place, so a final `<end>` was appended to `stableTokens` and rendered verbatim; and the stable/active seam used `joined(separator: " ")`, which produced `"你好 世界"` between CJK glyphs. A new `SonioxMessageDecoder` (nonisolated, pure) centralises the `controlTokens = {<end>, <fin>}` allowlist and returns the filtered stable/active tokens plus a `hasEndpointToken` signal, and the actor's message loop now routes the seam through the shared CJK-aware `TranscriptJoiner.join`. `enable_endpoint_detection` and every outgoing WebSocket message are unchanged; the fix is defensive on the read path (audit P1-13).
- Provider errors no longer echo hotwords, prompt fragments, or raw HTML pages back into the capsule/toast: `BatchTranscriptionClient` (both the OpenAI-compatible path and the shared JSON helper used by Deepgram/AssemblyAI/Soniox) and `BailianVocabularyService` used to throw `BailianRealtimeError.protocolError(String(data: data, encoding: .utf8))` for any non-2xx HTTP body, so an upstream 4xx/5xx that echoed the request (hotword list, prompt) or served a whole HTML error page landed verbatim in the user-visible error. The `ReasoningService.providerErrorMessage` sanitizer is now a shared `ProviderErrorSanitizer.message(from:statusCode:)` helper, and every raw-body error site routes through it: JSON `error.message` / `message` / `error` / `detail` fields are extracted and capped at 300 chars, HTML and oversize plain-text bodies fall back to `HTTP <status>`, and the raw body is still available to the redacted debug log unchanged (audit P1-12).
- Quitting the app or cancelling a model install no longer hangs when a child process ignores SIGTERM: `LocalModelInstallationService.ProcessCommand.execute` (audit P1-11) raced a task-group `process.waitUntilExit()` against a SIGTERM-only timeout task, so a pip/tar/venv child that swallowed SIGTERM wedged the group forever and `AppEnvironment.shutdown` awaited it uncancellably; `AudioCueService.runAdapter` (audit NEW-4) had the same shape and additionally left the child's stderr `Pipe()` undrained, so an adapter writing >64 KB to stderr blocked on the pipe until the 2.5 s SIGTERM (which a chatty adapter can ignore). Both sites now go through a new `SupervisedProcess.run` helper that bridges `Process.terminationHandler` to an async waiter (never `waitUntilExit` inside a `Task`), drains stdout/stderr via `readabilityHandler` with a 512 KB per-stream cap so a chatty child cannot block on a full kernel pipe, and escalates SIGTERM -> `killGrace` -> SIGKILL on both wall-clock timeout and cooperative `Task` cancellation. `LocalModelRuntime.terminate` already had the correct SIGTERM -> 500 ms -> SIGKILL escalation for its long-running server processes and is intentionally left alone.
- History no longer silently prunes without any user-facing disclosure: `HistoryRepository` has always dropped rows older than 90 days or beyond the newest 2000 on startup and after every save, but there was no UI hint, so users could not discover why old transcripts vanished. The history view now shows a small footer stating "Entries older than 90 days or beyond the newest 2000 are removed automatically." in all three locales (en, zh-Hans, zh-Hant), and `HistoryRepository.prune()` gains an optional `pruneLogger` seam that emits one info-level message with the delete count when non-zero (zero deletions stay silent so save-time prunes do not spam the log). The policy itself is unchanged; a settings toggle remains a separate future item (audit P1-8).
- "Clear history" no longer leaves plaintext transcripts on disk: `HistoryRepository` never set `PRAGMA secure_delete`, so DELETE freed pages without zeroing them and old transcripts lingered in the SQLite freelist (and in the `-wal` sidecar, which the bare DELETE also never checkpointed — a stale 2.3 MB `-wal` was observed). Every new connection now enables `secure_delete=ON`, `clear()` follows the DELETE with `PRAGMA wal_checkpoint(TRUNCATE)` + `VACUUM` so historical freelist pages and any tail WAL frames are wiped, and the repository's `deinit` runs one final `wal_checkpoint(TRUNCATE)` so single-row deletes cannot leave forensic residue in `-wal` past process exit (audit P1-7).
- Push-to-talk with a modifier-only hotkey (default Right Command) no longer gets stuck "held" when the user also holds the same modifier on the other side of the keyboard: `HotkeyService` inferred press state from the aggregate `CGEventFlags` mask, which cannot distinguish left vs right of Cmd/Shift/Option/Control, so releasing Right Command while Left Command was held left `.maskCommand` set and `pressed` stayed true until the 30-minute watchdog fired (the translation tap also kept swallowing global Cmd+`,` the whole time). The `flagsChanged` decision now pairs the mask test with a per-keyCode read from `CGEventSource.keyState(.combinedSessionState, key:)`, and after `.tapDisabledByTimeout` / `.tapDisabledByUserInput` re-enable the same `keyState` read reconciles `pressed` so a release that landed during the disabled window still fires `onRelease` (audit P1-5).
- Dictated text no longer lands in the text field you left: insertion tried the Accessibility element captured when dictation started before re-reading the live focus, and that stale element usually still is a writable text control, so clicking another field in the same app mid-dictation silently wrote the transcript into the old one. The live focused element is now read and written first, with the captured element kept only as a fallback for when that read fails (no element, `.apiDisabled`, timeout); the app-activation retry, paste fallback and permission handling are unchanged (audit P1-4).
- Dictated text no longer vanishes when macOS Secure Input is active (password fields, `sudo` in Terminal, some login forms): the window server drops the synthetic Cmd+V, the paste silently no-oped, and the ~900 ms clipboard restore then wiped the transcript off the clipboard too. The paste path now checks `IsSecureEventInputEnabled()` before posting keystrokes, keeps the transcript on the clipboard for a manual paste with no restore scheduled, and the capsule explains why in all three languages; the Accessibility insertion path is still tried first and the session still completes into history (audit P1-3).
- Realtime-only dictation (Bailian/Volcengine) no longer loses an essentially complete transcript when the socket dies during stop: the frame-send error path used to fail the session unconditionally, and failing runs `resetIfCurrent`, which wiped the captured PCM. The send-error catch and the realtime `.error` event now share one `degradeOrFailAfterRealtimeError` policy that keeps the retained partial (and audio) whenever a partial exists or the session is winding down, and only fails early when there is nothing to salvage (audit A2).
- "Allow local fallback" now actually works for realtime-only providers (Bailian/Volcengine): an empty realtime transcript used to throw "no speech" before the retained audio ever reached transcription, silently discarding the user's speech, because one flag conflated "this provider has no batch endpoint" with "there is no fallback at all". The empty-transcript path now checks the speech gate first (still "no speech" when nothing was said) and otherwise degrades through the remaining route — batch upload where the provider supports it, or the installed local Whisper model when local fallback is enabled (audit P1-2).
- A realtime finalize error or timeout no longer destroys the captured audio for realtime-only providers: with no partial transcript, `stop()` rethrew immediately and failing a session wipes the recorded PCM, so speech was lost even with local fallback available. That path now falls through into the same recovery ladder as the empty-transcript case, which routes the retained audio to the installed local model; when no fallback route exists the original provider error still surfaces instead of a misleading "no speech" (audit NEW-7).

## [2.0.10] - 2026-08-21

### Fixed

- "Show in Dock" off no longer breaks after reopening the control panel from Spotlight/Finder/Launchpad/Dock: reopening a running app sends kAEReopenApplication, during which AppKit resets the activation policy to the Info.plist regular type, so the Dock icon reappeared permanently once the window closed. `applicationShouldHandleReopen` now restores the accessory policy when the user has Dock display off.

### Removed

- Legacy Electron settings migration: all users have migrated, so the first-launch importer (Chromium Local Storage / `.env` reader, migration coordinator, allowlist mapping) and the `swift-leveldb` package dependency are gone, along with the `MOUTHPIECE_SKIP_LEGACY_MIGRATION` escape hatch and migration-only `SettingsRepository` helpers (~600 lines, 7 tests). The legacy model-cache directories are intentionally kept — local models downloaded by the Electron version are still discovered without re-downloading.

## [2.0.9] - 2026-08-13

### Fixed

- Translation hotkey reliability: `restartForTranslation` now retries (bounded, 3 attempts) when a queued main-hotkey start claims the session slot during its cancel/settle window, instead of silently no-oping and leaving an untranslated normal session running; the pending main-hotkey press checks for cancellation after its 140 ms suffix-wait so a translation suffix press can no longer race it. Session-start logs now carry a `translation` marker, ignored suffix presses and failed translation restarts are logged, making future misses diagnosable from the debug log.

## [2.0.8] - 2026-08-10

### Added

- R2 structural batch from the 2026-08-07 improvement audit, all cross-reviewed (15/15):
  - Recording now reacts to input-device loss: the audio engine observes configuration changes for the live session and surfaces "microphone connection interrupted" through the normal failure path instead of silently showing a frozen recording UI (A1); the converter pool validates buffer formats on return (A2) and counts dropped frames, rebuilding undersized buffers and logging drop totals at session end (A3).
  - Dictation stop now drains all queued audio frames to the provider before finalizing, so trailing words can no longer be lost to the frame-stream race (B2); switching to a translation session mid-dictation is an atomic coordinator operation driven by real state instead of a published UI snapshot (B4); a realtime provider error no longer kills a session that already has partial text or is winding down — it degrades to the partial/batch fallback (C1, coordinator and all five providers).
  - Provider plumbing consolidated into a shared RealtimeSocketSession (buffer caps, chunk flushing, finish polling, benign-close handling) removing ~100 lines of drifted duplication; all five providers now confirm the connection during connect so bad API keys fail fast (C5, C6 — Deepgram/Soniox use pong/first-message confirmation as an approved deviation).
  - History storage gains an automatic retention policy (90 days / 2000 rows with periodic VACUUM), a 3-second SQLite busy timeout, and SQL-side search with escaping plus stable pagination and a "Load more" UI — old records are now searchable instead of silently invisible beyond the first 200 (F1, F7, D7).
  - The overview page keeps the last session error for review with copy/clear (D6), the capsule posts VoiceOver announcements on phase changes (D8), and a sidebar banner warns when Accessibility permission is missing with a direct System Settings link (D12).
  - Release chain: the DMG Finder-layout step fails loudly with a retry and read-back verification instead of `|| true` — Finder-readback verification was dropped after proving unreliable on headless CI (-1728/-10000); the gate is the strict apply-with-retry plus a non-empty .DS_Store (E7), and each release's Sparkle appcast now merges up to five previous versions' entries so withdrawing a release leaves a working update path (E8, hosted on release assets — no gh-pages migration by design).
- R1 engineering guardrails from the 2026-08-07 improvement audit, all cross-reviewed:
  - Lint toolchain (E6): repo-level `.swiftlint.yml` (Native-only, thresholds tuned so existing code passes with zero errors) and `.swiftformat` (check-only safe-rule whitelist); CI gains a `lint` job running SwiftLint, `swiftformat --lint`, and shellcheck — all three pass locally with zero errors.
  - CI hardening (E5): workflow-level `concurrency` with cancel-in-progress, per-job `timeout-minutes`, and SPM + Homebrew caches; newly added actions are SHA-pinned like the rest.
  - Weekly upstream smoke job (E2): a scheduled/dispatchable `upstream-smoke` job builds `download-native-binaries.sh arm64` so a broken whisper.cpp/sherpa-onnx/mediaremote toolchain surfaces within a week instead of on release day; scheduled runs skip the regular test jobs.
  - Test observability (E12): tests write an xcresult bundle that is uploaded on failure, and successful runs print a line-coverage summary.
  - Core-path test coverage (E4①-⑤, +14 tests, suite now 109): DictationCoordinator orchestration with a scripted stub provider (connect-failure recovery, realtime completion into history, cancel suppressing late events); KeychainStore round-trip/overwrite/delete against an isolated service; AssemblyAI and Deepgram protocol fixture decoding including turn merging and finalize paths; TextInsertionService insert() decision flow (sensitive-app block, dead target, AX fallback, per-app paste delay); UpdateController feed selection per architecture, activation gating, and keyless no-op. Seven minimal test seams (default-preserving injection points and access-level changes) verified behavior-neutral by the independent reviewer.

### Fixed

- R0 quick-win batch from the 2026-08-07 improvement audit (docs/audits/2026-08-07-improvement-plan.md), all cross-reviewed:
  - Hotkeys: the translation suffix hotkey no longer swallows global shortcuts (for example every app's `Cmd+,`) while dictation is idle — it is armed only while the main dictation key is held (B1); refreshing hotkey registrations on app activation/wake no longer resets a held push-to-talk key, so releasing it reliably stops recording, and changing the key mid-press now emits the missing release first (B3); the hotkey recorder rejects bare character keys (typing "a" anywhere could start dictation) while still allowing modifier combos, pure-modifier keys, and F1–F19 — F13–F19 parsing was added (D2).
  - Dictation flow: stopping while still preparing (fast double toggle) cancels silently instead of flashing a "no audio" error (B7); silent sessions fail fast with "no speech" instead of uploading the whole recording for batch transcription and risking Whisper hallucinations (B8); cancelled/failed sessions release the capture buffer (up to ~57 MB after long recordings) instead of keeping its capacity (B9); media pause no longer delays microphone startup — it runs in parallel and is awaited before resume (A5); when cleanup/translation fails, the capsule briefly shows "Refining failed, using the raw transcript" instead of silently inserting the raw text (D5).
  - Onboarding: the try-it page swallows Esc/dictation keys only while actually recording, a failed attempt can be retried in place, and a "Skip this step" button unblocks users without a working microphone (D3, D4).
  - Providers: Deepgram/AssemblyAI missing-key and timeout errors now name the right provider instead of "Alibaba Bailian" (C3); server-reported errors end finalization immediately with the real message instead of idling 5 s into a fake timeout (Deepgram/AssemblyAI/Bailian, C7); Chinese transcripts from Deepgram/AssemblyAI no longer get spaces between CJK segments (C10); start/stop cue WAVs are synthesized once and cached instead of per playback on the main actor (A8).

### Changed

- Translation now requires text processing: enabling translation turns the cleanup model on, disabling cleanup turns translation off, and stored settings with the stale "translation on, cleanup off" combination are normalized on load; the settings page explains the dependency in all three languages (audit D1, revised per product decision — no separate credential entry for translation).
- README (zh/en) and the code-signing runbook now describe the real first-launch path on macOS 15+ ("System Settings → Privacy & Security → Open Anyway"); the right-click-Open workaround no longer exists for unnotarized apps (E3 docs).
- Release hygiene: the version validator caps minor/patch at 99 so build numbers stay monotonic (E9), the Homebrew cask declares `auto_updates true` so `brew upgrade` stops reinstalling over Sparkle updates (E10), and the signing-certificate fingerprints live only in the signing/verification scripts instead of being duplicated in the release workflow (E11).

### Security

- All GitHub Actions in CI and release workflows are pinned to commit SHAs (tags kept as comments) so a hijacked action tag cannot exfiltrate the Sparkle private key or signing material; Homebrew formula pinning was evaluated and skipped as impractical (E1).
- Gemini requests send the API key in the `x-goog-api-key` header instead of the URL query string, keeping it out of proxy and system logs (C4).
- The debug-log redactor also masks Gemini (`AIza…`) and Groq (`gsk_…`) keys and credential-bearing URL query parameters (F4).
- The legacy-migration backup no longer keeps a plaintext `.env` copy of all API keys — values are redacted after a successful backup — and deleting the backup folder no longer re-triggers migration (F2).
- Sensitive-app protection now also covers clipboard retention and history storage, not just automatic paste insertion (F3).

## [2.0.7] - 2026-08-07

### Fixed

- Fixed dictation being impossible to start after switching microphones ("Starting the microphone failed: Failed to create tap due to format mismatch") until the app was relaunched: the long-lived audio engine kept the previous device's cached input format, and the tap was installed with that stale format. Each session now creates a fresh `AVAudioEngine`, the tap is installed with a `nil` format so it always follows the node's live format (no format-mismatch exception exists anymore, even when the device changes between the format read and the install), and the audio converter plus its buffer pool are rebuilt on the fly from the format of the buffers that actually arrive — so even a mid-recording device switch (built-in 48 kHz ↔ Bluetooth HFP 16 kHz) keeps capturing seamlessly.
- Fixed a crash when dictating into Mouthpiece's own windows (dictionary editor, prompt studio, history search): inserting into our own process went through the Accessibility SetValue path, and in-process AX requests execute AppKit's handler directly on the calling background thread — `NSTextView`/TSM then trip a main-queue dispatch assertion (SIGTRAP, observed Aug 5 on v2.0.6). Self-targeted insertions now skip Accessibility entirely (no focused-element read, no SetValue) and use the synthetic-paste path, which is delivered through the main event loop; external-app insertion is unchanged.

### Changed

- README (Chinese and English) now documents the Homebrew cask install (`brew install --cask NotWizard/mouthpiece/mouthpiece`) and the built-in Sparkle automatic updates; both shipped with the release pipeline but were missing from the installation docs.

## [2.0.6] - 2026-08-03

### Fixed

- Fixed the app silently vanishing when starting dictation right after the input device changed (AirPods connect/disconnect, headset plug/unplug): `AVAudioEngine`'s `installTapOnBus`/`start` raise Objective-C `NSException`s (for example a stale cached format that no longer matches the hardware) that Swift `do/catch` cannot intercept, and the `NSApplicationCrashOnExceptions` fail-fast registered in 2.0.2 turned them into instant process death with no visible error — three identical crash reports (v2.0.4/v2.0.5, all in `AVAudioEngineImpl::InstallTapOnNode` on the audio-engine queue) confirmed the pattern. Both calls now run through a small Objective-C `@try/@catch` shim that converts the exception into a normal "Starting the microphone failed" dictation error, and a defensive `removeTap` before installing rules out double-install as well; the session fails visibly and the app survives for an immediate retry.

## [2.0.5] - 2026-08-01

### Added

- Added `qwen-audio-3.0-asr-flash-streaming` as the default Alibaba Bailian realtime transcription model while retaining selectable `fun-asr-realtime` support. Qwen uses inline dictionary hotwords; Fun-ASR continues using the existing managed Bailian vocabulary.

### Documentation

- Added a complete implementation plan for supporting both Qwen Audio 3.0 ASR Flash Streaming and Fun-ASR Realtime within the Alibaba Bailian provider, covering model selection, migration, hotwords, WebSocket lifecycle, tests, and acceptance criteria.

### Fixed

- Fixed the model information tooltip not appearing reliably when hovering the small hint icon in the Alibaba Bailian and Volcengine transcription settings by giving the icon a stable pointer target.

## [2.0.4] - 2026-07-23

### Fixed

- Fixed a guaranteed crash (`SIGTRAP` in `Data.subdata(in:)`) moments after starting dictation with the Bailian realtime provider, introduced in 2.0.3's send-backlog chunking change: the flush used zero-based indices (`subdata(in: 0..<n)`, `insert(at: 0)`) on the pending-audio buffer, but `Data.removeFirst` leaves `startIndex` non-zero, so the second flush tripped a range precondition. Chunk detaching now goes through an index-safe helper (`Data(prefix)`/`Data(dropFirst)` rebuild fresh zero-based values) with a regression test that drives multiple flush rounds over a shifted buffer.

## [2.0.3] - 2026-07-23

### Fixed

- Fixed the control panel window sinking behind the previously frontmost app right after launch when "Show in Dock" is off: async startup finished by switching the activation policy to accessory, which deactivates the app, so the window flashed and dropped behind (for example) Terminal. The policy is now only changed when it actually differs, and if the app was active before the switch it is re-activated and the main window brought back to front — the same guard also keeps the window in front when toggling the Dock setting.
- Fixed dictation getting stuck at "Finalizing" forever when the realtime transcription connection is half-dead (TCP alive but the server no longer responds): `provider.finish()` had no timeout, so a hung WebSocket send wedged the whole dictation coordinator and blocked every later start/cancel. Finalization is now raced against an 8-second deadline through an abandonable task; on timeout the session falls back to the latest partial transcript or batch transcription, exactly like any other finalize failure.
- Closed a use-after-free crash window in the hotkey event tap: the CGEvent tap callback holds an unretained pointer to the `HotkeyService` instance and the main run loop retains the tap source, so releasing a service without calling `stop()` (for example while swapping hotkey configurations) left a live callback pointing at freed memory. The service now tears the tap and run-loop source down in `deinit`.
- Fixed live transcription silently freezing when the realtime connection goes half-dead mid-session (Wi-Fi switch, VPN drop, idle connection dropped by a load balancer): all five realtime providers (Bailian, Volcengine, AssemblyAI, Deepgram, Soniox) waited on `socket.receive()` with no timeout, so a silent server left the capsule showing a stale transcript with no error. Receives now go through a shared abandonable 60-second timeout that surfaces "server stopped responding" through the normal error path; Bailian's handshake reuses the same helper, replacing a task-group variant that could wait on a hung child.
- Fixed the user's clipboard being lost when two dictations complete within about a second of each other: the second paste snapshotted the pasteboard while it still held the first dictation's transcript, so the delayed restore later overwrote the user's real clipboard with that transcript. A new paste now cancels the previous pending restore and inherits its original clipboard snapshot whenever the pasteboard still contains our own text.
- Eliminated a data race on the audio engine when restarting dictation quickly: session start touched `AVAudioEngine.inputNode` and installed the tap on the main thread while the previous session's tear-down (`removeTap`/`stop`) could still be running on the background engine queue, which could double-install the tap or corrupt engine state. The whole session setup (device selection, format read, tap install, engine start) now runs as one block on the same serial engine queue, so it always waits for any in-flight tear-down.
- Fixed the legacy `.env` migration storing API keys with literal quotes when a quoted value had a trailing comment (`KEY="sk-…" # note`): the quote check required the line to end with the quote, so such lines fell through to comment stripping and the surrounding quotes leaked into the Keychain, making every API call fail with an invalid key. The parser now takes the quoted body up to the matching closing quote (a `#` inside quotes is preserved).
- Stopped corrupted saved settings from silently wiping the user's configuration: when the stored settings blob failed to decode (OS upgrade, disk corruption), the app quietly fell back to factory defaults with no trace. It now logs the failure, keeps the unreadable data in place for recovery, and shows a startup alert telling the user that defaults were loaded.
- Turning off debug logging now really turns off all logging: session metadata (phase changes, target app names, error details) was still written to the macOS unified log — readable via Console.app — even with the toggle disabled, because the enabled check ran only after the system-log calls. The check now runs first, so nothing is logged anywhere while the toggle is off.
- Fixed combination hotkeys (for example `Command+K`) getting stuck in the pressed state when the modifier key is released before the main key: the modifier's release event carries its own key code and never reached the hotkey handler, so hold-to-dictate kept recording until the main key was also released. Modifier releases now end the press immediately.
- Stopping dictation during the preparing phase now cancels the 15-second preparing watchdog like every other exit path; previously the watchdog stayed armed and could fire in the middle of an in-flight stop, diverting the session into the failure path instead of the normal stop flow.
- The failure handler now marks the session failed before tearing down audio, media playback, and the realtime connection; previously another queued action (a user stop or the maximum-duration cut-off) could take over the session between those tear-down steps and the final state check, after side effects that could not be rolled back had already run.
- Cancelling a dictation session in the brief window right after the synthetic paste no longer leaves the transcript stuck on the clipboard: the delayed clipboard restore was only scheduled after a cancellable pacing sleep, so a cancellation skipped it entirely. The restore is now registered before that sleep and always runs.
- Repeated text insertions into a hung application can no longer exhaust the app's background thread pool: every timed-out Accessibility call abandons one blocked worker thread, and there was no cap, so a persistently unresponsive target could drain all ~64 GCD threads and stall unrelated background work. Abandoned threads are now counted, and once eight are outstanding new Accessibility attempts are skipped in favor of the Cmd+V paste path until the stuck calls return.
- When a modifier-only hotkey (for example Right Command) is set to swallow its events, the release edge is now swallowed too: previously only the press was consumed, so the frontmost app received an unpaired modifier-up that could trigger menu-bar highlights or shortcut hints.
- The capsule now repositions itself after the Mac wakes from sleep: the wake observer was registered on the wrong notification center (`NotificationCenter.default` instead of the workspace's), so it never fired and a monitor-layout change during sleep could leave the capsule stranded off-screen. Both capsule observers are also removed on tear-down now, fixing a small observer leak.
- Downloaded Whisper models are validated more strictly before being accepted: the previous check only required 80% of the expected file size, so a truncated download or an HTML error page saved by a CDN could be installed and crash the local transcription engine at load. The check now requires 95% of the expected size plus the ggml file signature (verified against the real published models).
- Soniox live transcription no longer re-emits the entire confirmed transcript on every server message: the confirmed text only grows, but each incoming message re-sent it as a fresh final update, causing needless UI refreshes during continuous speech. Final updates are now sent only when the confirmed text actually changes.
- The legacy-app migration can no longer be re-triggered by the native app's own data: the app's own support folder was the first migration-source candidate and its own history database matched the legacy detection, so a missing migration marker (for example after a partial reinstall) started a bogus migration and created pointless backups. In the app's own folder, only Electron-specific artifacts (`.env`, `Local Storage`) now count as legacy state.
- Fixed continuous-integration checks failing on every version bump: the CI script-verification step validated a hardcoded `2.0.0` against `project.yml`, so main went red as soon as the version moved past it. The check now derives the version from `project.yml` itself. The CI test job also gained `CODE_SIGNING_ALLOWED=NO` (matching the Intel job), and the release workflow passes the manually-dispatched version through an environment variable instead of inlining it into the shell script, removing a command-injection surface.
- A stalled local-model download now fails within two hours instead of hanging for up to seven days: the shared URL session's default resource timeout effectively never fired for multi-gigabyte Whisper/Parakeet downloads, leaving the install button stuck on a dead connection.
- Local transcription server failures are now diagnosable: the whisper/sherpa/Qwen server processes had their output discarded, so a crash at startup only ever reported "startup timed out" with no reason. Each server's output is now kept in a per-model log file under the app's logs folder, and startup errors include the last lines of that log.
- Parakeet local transcription no longer freezes forever when the local recognition server wedges (memory pressure, corrupt model): its WebSocket wait now uses the same 60-second abandonable timeout as the cloud providers and surfaces an error instead.
- Bailian hot-word sync issues are no longer invisible: a failed vocabulary sync is now logged with its reason (the session still proceeds without hot words), and the vocabulary cache expires after 30 minutes so a vocabulary deleted on the server side stops being reused indefinitely. Sending buffered audio after a network stall also no longer reshuffles the whole backlog for every chunk.
- Text-processing errors now show the provider's human-readable message (for example "Invalid API key") instead of dumping the raw response body — which could be a full HTML error page or include internal request identifiers — into the alert.

### Changed

- Local Xcode Debug builds are now signed with the same stable "Mouthpiece Code Signing" certificate as releases (`project.yml` sets `CODE_SIGN_STYLE: Manual` + `CODE_SIGN_IDENTITY`) instead of ad-hoc signing. Ad-hoc signatures change on every build, so each rebuilt Debug app failed the Keychain ACL check on the stored API-key items and macOS prompted for keychain authorization again and again; with a certificate-based designated requirement the grant persists across rebuilds (TCC grants benefit likewise).
- Audio frames now flow through a single per-session consumer stream instead of spawning one concurrency task per 20-millisecond frame (about 50 per second, ~90,000 over a half-hour session), reducing scheduler and memory pressure during long dictations.
- Long recordings use far less memory while being transcribed: the raw capture buffer (about 2 MB per recorded minute) is released as soon as the trimmed copy is made, and the WAV payload buffer is pre-sized, so a 30-minute batch transcription no longer holds three full copies (~170 MB peak) of the audio at once.
- Each 20-millisecond microphone frame now has its loudness (RMS) computed once instead of twice: the audio converter already measures it for the waveform level, and the speech-activity gate now reuses that value instead of re-scanning every sample.
- Volcengine realtime messages are now parsed in place instead of copying every incoming frame into a fresh byte array, removing a per-message full-payload allocation during continuous speech.
- Local-model audio preprocessing (16-bit to float conversion and loudness measurement for Parakeet/Qwen chunks) now uses the system's vectorized signal-processing routines instead of per-sample Swift loops, cutting the conversion cost of each 15-second chunk substantially.
- The capsule waveform now draws all bars as one combined path per frame instead of allocating and filling ~36 separate paths, trimming per-frame drawing overhead on high-refresh displays.
- The history page filters its records once per view update instead of twice, halving the search work performed whenever the app state refreshes while history is on screen.
- Removed an unreachable branch from the capsule content resolver (the processing phase is handled by an intentional early return so "Refining…" wins over a partial transcript); no behavior change.
- Hardened the native-runtime download script: every download now has connect/transfer timeouts (a stalled CDN connection previously hung the build for hours), the deprecated `find -perm +111` syntax was replaced with `-perm -111` (the interim `/111` form was GNU-only and aborted the macOS release build), and the executable bit is now applied only to actual binaries, dylibs, and scripts instead of every packaged file (including licenses).
- Debug logging keeps its log file open across entries instead of opening and closing it for every line, removing needless file-system churn during busy dictation sessions.
- The release smoke test now polls the launched app over a five-second window instead of a single fixed three-second check, so a slow CI runner no longer produces false failures and an early crash is reported with the launch log attached.
- Removed a force unwrap in the model-installation command runner; an exotic cancellation ordering now surfaces as a cancellation error instead of a potential crash.
- The accessibility-permission guide now stops its background permission polling after ten minutes and hides itself, instead of checking every 200 milliseconds indefinitely if the guide is left open without granting.
- Assorted hygiene: automatic updates being disabled by a missing signing key is now logged instead of silent; the Sparkle feed fallback in the app manifest points at a feed that actually exists (the runtime still picks the right architecture) — and since `generate_appcast` names its output after that embedded feed filename, the release workflow now globs the generated appcast instead of expecting a literal `appcast.xml`; the diagnostics page shows a dash instead of a stale hardcoded version when the bundle version is unavailable; saving settings no longer performs a redundant reload; and the release pipeline fails fast when release notes are missing their title line.

### Security

- Pinned SHA256 checksums for all three external artifacts fetched by `scripts/download-native-binaries.sh` (whisper.cpp source, sherpa-onnx release archive, mediaremote-adapter source); the build now aborts on any checksum mismatch instead of compiling unverified downloads into the shipped app, closing a supply-chain attack path via compromised upstream releases or a man-in-the-middle on the download.
- Pinned the SHA256 checksum of the Sparkle 2.9.4 archive downloaded in the release workflow's appcast step; a tampered `generate_appcast` binary could otherwise sign a malicious appcast with the project's own EdDSA key and push a rogue auto-update to every user.
- Moved the AssemblyAI streaming API key from the WebSocket URL's `token` query parameter into the `Authorization` header (per the official v3 streaming docs); a key in the URL could leak into corporate proxy logs, debugging proxies, and system connection logs.
- The release build no longer installs the self-signing certificate into the CI runner's system trust store (`sudo security add-trusted-cert` into `/Library/Keychains/System.keychain`): signing only needs the identity in the job's temporary keychain, `codesign --verify` does not evaluate trust, and the artifact verifier already tolerates the untrusted Gatekeeper outcome. An interrupted job could previously leave the certificate trusted system-wide on shared runner images.

## [2.0.2] - 2026-07-22

### Fixed

- Fixed delayed, random `EXC_BAD_ACCESS` crashes (quit menu, control-panel view updates, Dock reopen) that struck minutes after a dictation session: capturing the dictation target ran an unbounded synchronous Accessibility call to the frontmost app on the main thread, and when that app hung, HIServices spun its exception machinery there and a swallowed ObjC exception corrupted the main thread's Swift concurrency executor state — any later `@MainActor` isolation check could then dereference a dangling executor pointer. The focused-element lookup now runs through the existing background race with a 1.5-second timeout, so the main thread never blocks on AX messaging.
- Registered `NSApplicationCrashOnExceptions` so AppKit no longer swallows ObjC exceptions; if one ever occurs again the app fails fast at the true source with an actionable crash report instead of running on with poisoned state and crashing somewhere unrelated later.
- Fixed occasional freezes when starting dictation (typically the first attempt after overnight sleep/wake): a dictation session stuck in the `preparing` phase now fails with a visible "Starting dictation timed out" error after 15 seconds instead of hanging indefinitely. Contributing stalls were also bounded — `AVAudioEngine` start/stop now run on a background serial queue so a wedged CoreAudio HAL can no longer block the main thread (which froze the whole UI for up to minutes), and the optional Bailian vocabulary request timeout was cut from the 60-second default to 10 seconds so a stalled network cannot delay realtime connection.
- Routed the status-menu Quit item directly to `NSApplication.terminate(_:)` through the responder chain instead of a Swift `@MainActor` action method, dodging a macOS 26 runtime crash (`EXC_BAD_ACCESS` in `swift_task_isCurrentExecutor`) observed when quitting after a long-idle session left the main thread's executor state corrupted.

## [2.0.1] - 2026-07-21

### Changed

- Reworked the capsule waveform so bar height reflects absolute microphone loudness — RMS mapped in dBFS onto a fixed −50…−6 window with fast-attack/slow-release ("breathing") smoothing — gated by speech activity, replacing the previous SNR-relative measure that saturated near full scale and drifted with the adaptive noise floor. When only background noise is present the bars now show a gentle, mic-independent idle pulse instead of jittering to ambient sound, and steady speech renders a steady, continuous level.
- Bundled the third-party `mediaremote-adapter` (BSD-3-Clause, pinned commit, built via CMake during `scripts/download-native-binaries.sh` into `Native/Binaries/mediaremote`) plus its Perl bridge, so media pause/resume can work on macOS 15.4+ without a private entitlement.
- Switched the control panel from a `WindowGroup` to a single-instance `Window` scene and removed the duplicate `Settings` scene, so the window reopens reliably and the reopen-time hosting-view rebuild crash path is eliminated.
- Restored a guided DMG install window that places `Mouthpiece.app` on the left and the `Applications` folder on the right with a branded drag-arrow background; the native packaging path previously produced a bare Finder window with default alphabetical icon placement and no background. The layout is applied via a HiDPI background and Finder icon positioning during the release build.
- Made the native-runtime download step in `scripts/download-native-binaries.sh` resilient to intermittent GitHub asset CDN outages by adding curl retry flags (`--retry 5 --retry-all-errors --retry-delay 3`) to both the whisper.cpp source and sherpa-onnx release-asset downloads, so a single transient connection failure to `release-assets.githubusercontent.com` no longer aborts the whole release build.
- Added a one-time `latest-mac.yml` generation step to the release workflow that points legacy Mouthpiece 1.4.x (Electron) users at the native 2.0.0 `arm64` mac.zip so they can auto-update past the Sparkle transition; only this release ships the file, subsequent versions ride the Sparkle appcast.
- Added a distinct capsule `processing` phase between transcription and insertion so the capsule shows a localized "Refining…" message while the LLM cleanup or translation request is in flight, instead of leaving a frozen raw transcript on screen.

### Fixed

- Fixed dictation getting stuck at "Refining…" for a long time when the text-processing model is a hybrid thinking model (for example Alibaba Bailian `qwen3.x`). The app never sent `enable_thinking`, so such models default to thinking ON and a non-streaming cleanup call spends most of its tokens reasoning (seconds to minutes); the reasoning request timeout was also 120 seconds. Now `enable_thinking` is sent explicitly for Bailian (off unless you enable it), the reasoning request timeout is cut to 30 seconds, and pressing Escape aborts the in-flight reasoning request instead of only discarding its result.
- Fixed the menu-bar "Open Control Panel" item (and Dock reopen) doing nothing once the control-panel window had been closed: `openControlPanel` only re-fronted an existing window and never created one, but SwiftUI destroyed the `WindowGroup` window on close, leaving nothing to bring back. The control panel is now a single-instance `Window` scene reopened through the SwiftUI `openWindow` action, which the status menu and Dock reopen invoke via a captured bridge, so it reliably comes back without rebuilding the `NSHostingView` (the rebuild that crashed on reopen). The duplicate `Settings` scene that rendered the same view and shared the same `@StateObject` was removed to eliminate the cross-scene state sharing implicated in that crash. Dock icon visibility remains governed solely by the existing "Show in Dock" setting.
- Fixed "pause other media during dictation" not pausing anything on macOS 15.4 and later (including macOS 26 Tahoe): `mediaremoted` now authorizes playback commands by the caller's code-signing identity, so a hardened, self-signed app's in-process `MRMediaRemoteSendCommand` reports success but is silently dropped (and the `com.apple.mediaremote.set-playback-state` entitlement is private and unobtainable by third parties). Detection and pause/resume now run through a bundled `mediaremote-adapter` framework invoked via the system `/usr/bin/perl` (which `mediaremoted` trusts as `com.apple.perl`), so Chrome/Safari/Music/Spotify and other now-playing apps pause when dictation starts and resume when it ends; the legacy in-process path stays as a fallback when the adapter is unavailable.
- Fixed automatic paste intermittently inserting nothing in some apps, including GPU terminals like Ghostty and Electron/browser-based or busy apps. Two causes: the original clipboard was restored ~90-220ms after the synthetic paste, before apps that read the pasteboard asynchronously had consumed it; and the accessibility text set (`kAXSelectedTextAttribute`) reported success as a no-op on terminals that expose no editable text element, so the code returned before ever sending Cmd+V. Now the AX write is gated by an editable role and verified by reading the value back — if it did not truly insert, insertion falls through to the synthetic paste path — the target app is always brought to the front first, the frontmost wait is extended, and the clipboard is restored only after a longer delay (still skipped if you copied something new).
- Stopped the Escape hotkey tap from swallowing the ESC key system-wide: the escape tap runs persistently as an active `.defaultTap` whenever "Escape cancels recording" is enabled, but its swallow decision had no active-session gate, so every bare ESC press was consumed and never reached any app, whether or not dictation was running. Swallowing is now armed only while a dictation session is active (driven from the dictation phase snapshot), so ESC behaves normally at all other times while still cancelling an in-progress session.
- Allowed dictation to target Mouthpiece itself when the app is frontmost (control panel, prompt-studio test tab) so testing a prompt from within Mouthpiece inserts the transcript into its own focused field instead of leaking it into the previously active application; a second Mouthpiece instance remains excluded as a target.
- Moved the capsule `ScrollerHider` probe inside the `ScrollView` content subtree and looked the backing `NSScrollView` up through `NSView.enclosingScrollView`; as a `ScrollView`-level background the probe was a sibling of the scroll view, so neither the superview walk nor the descendant search could ever reach it and the vertical scrollbar stayed visible on multi-line transcripts.
- Made the Accessibility insertion timeout real: the previous `withTaskGroup` race could not abandon a blocked AX call (structured concurrency waits for every child on scope exit), so a hung target application stalled the inserting phase indefinitely. AX calls now race on unstructured GCD threads with a double-resume guard, the focused-element read timeout is tightened to 1.5 seconds, and a genuine timeout deterministically falls through to the Command+V paste path.
- Degraded realtime finalize failures to the latest partial transcript: when `provider.finish()` times out or errors but usable transcript text already exists, the session continues with that text through refinement and insertion instead of failing outright for realtime-only providers (Bailian, Volcengine); sessions with no received text still fail as before.
- Intercepted the macOS dock-reopen Apple event in `AppDelegate.applicationOpenUntitledFile` so re-activating the app brings the existing control-panel window forward instead of letting SwiftUI rebuild the `NSHostingView`, which dereferenced a corrupted `@MainActor` executor and crashed with `EXC_BAD_ACCESS` at `0xaaaaaaaaaaaaaad0` roughly two minutes after launch.
- Moved blocking Accessibility API calls in `TextInsertionService` off the main thread with a 3-second timeout so an unresponsive target application can no longer freeze the dictation capsule or prevent ESC/hotkey cancellation during text insertion.
- Hid the vertical scrollbar that appeared in the capsule transcript area by disabling the scroller on the underlying `NSScrollView`.

## [2.0.0] - 2026-07-19

### Changed

- Replaced Alibaba Cloud Bailian Qwen ASR Flash transcription with the dedicated `fun-asr-realtime` WebSocket path, including binary PCM streaming, incremental sentence updates, and dictionary-backed hotword synchronization.
- Fixed the Bailian model to `fun-asr-realtime` in settings and removed its realtime toggle and batch-transcription fallback.

### Fixed

- Allowed the hardened self-signed app to load its bundled Sparkle framework so Homebrew and DMG installations launch normally on user machines.
- Updated the generated Homebrew cask to use the current symbolic macOS dependency syntax.
- Generated separate signed Sparkle feeds for Apple Silicon and Intel packages so both architectures can publish the same app version without conflicting appcast entries.
- Reacquired stale Accessibility focus and activated the original target application before synthetic paste so automatic insertion no longer fails intermittently after delayed transcription.
- Displayed target-application identity throughout capsule preparation instead of briefly flashing a preparing message.
- Treated provider transcripts as authoritative when local voice activity detection misses quiet speech, while distinguishing empty microphone capture from genuine silence.
- Normalized the capsule waveform against the adaptive ambient-noise floor and removed low-level visual amplification so silence no longer appears near full scale.
- Included the required empty `payload.input` object in Bailian Fun-ASR `finish-task` WebSocket messages so completed dictation sessions can finish cleanly and reach text processing.
- Removed automatic Bailian realtime warmup during launch, credential changes, and wake recovery so a slow WebSocket handshake cannot block the first dictation hotkey behind an in-flight provider task.
- Corrected the native artifact architecture check so both arm64 and x86_64 release packages are validated with the supported `lipo` argument order.
- Pinned the LevelDB migration dependency to a Swift 6.2-compatible manifest and selected Xcode 26.3 explicitly on macOS 15 runners so the package resolves consistently across the supported test matrix.
- Removed the rectangular native window shadow around the rounded dictation capsule and moved waveform animation onto a display-synchronized AppKit renderer without publishing audio levels through the global application state.
- Enlarged and optically centered the Mouthpiece interface and menu-bar marks so they align cleanly with adjacent text and system status icons.
- Removed the redundant macOS Accessibility prompt when the app already opens System Settings and provides its drag-to-authorize guide.
- Kept the control panel in its intended titleless full-content layout after onboarding instead of restoring the standard macOS toolbar and duplicate window title.
- Stabilized the dictation capsule across recording, processing, transcript, and error states by keeping one fixed frame and replacing content within a reserved slot.
- Split the Mouthpiece brand mark into interface and compact menu-bar assets so sidebar branding stays legible while small system surfaces remain centered and uncluttered.
- Serialized local model installation and removal, cancelled tracked model operations during shutdown, and kept model-operation UI state stable across provider changes.
- Removed application and workspace notification observers during shutdown instead of leaving lifecycle callbacks registered.
- Escalated unresponsive local model server termination after a bounded grace period so shutdown cannot leave child processes running.
- Isolated API-key editor state by provider and ignored stale credential loads so switching providers or typing during a load cannot reveal or overwrite the wrong key.
- Prevented asynchronous initialization and realtime warmup work from restarting integrations after application shutdown begins.
- Ignored stale asynchronous debug-log toggle updates when settings change again before the logger actor applies them.
- Closed realtime transcription providers after finalize failures before continuing with successful batch fallback, preventing abandoned WebSocket connections.
- Prevented cancelled or replaced realtime WebSocket connections from mutating a newer transcription session across Bailian, Soniox, Deepgram, and AssemblyAI.
- Positioned the recording capsule on the display containing the target application's front visible window, with mouse-screen fallback when no window can be resolved.
- Continued deleting uploaded Soniox files and transcription jobs in an independent bounded cleanup task after the parent transcription is cancelled.
- Treated launch-at-login approval as an already registered state, avoiding repeated denied registrations and unregistering it correctly when the setting is disabled.
- Retained pending media-resume state when playback restoration fails or cannot be confirmed, allowing later session cleanup to retry instead of leaving media paused indefinitely.
- Restored the previous clipboard contents when synthetic paste setup fails or its settling delay is cancelled, instead of leaving the temporary transcript behind.
- Rejected malformed or unknown hotkey modifiers during settings normalization instead of silently turning them into unsafe shortcuts.
- Required exact modifier flags for ordinary hotkey combinations so extra held modifiers no longer trigger or swallow the wrong shortcut.
- Filtered unrelated global keyboard events before scheduling main-thread hotkey work, eliminating redundant tasks for ordinary typing.
- Deferred cloud transcription and reasoning model-name persistence until editing completes instead of rewriting the full settings payload for every keystroke.
- Applied system integrations, hotkey registration, logging, and local-model refreshes only when their related settings change instead of on every control-panel keystroke.
- Validated focused Accessibility object types before insertion instead of crashing when an application returns an unexpected Core Foundation value.
- Combined every Anthropic and Gemini response text block instead of silently returning only the first provider segment.
- Recursively filled missing nested setting defaults so older terminology profiles no longer cause the entire settings file to be discarded.
- Normalized the in-memory settings restored after a failed legacy migration so rollback cannot temporarily bypass current runtime invariants.
- Allowed custom provider base URLs to be entered as a draft and validated on submit or focus loss instead of resetting the field after every partial keystroke.
- Closed each Parakeet transcription WebSocket on send, receive, and completion paths instead of leaking failed segment connections.
- Closed Bailian WebSockets when warmup, connection, or reconnection handshakes time out or fail before configuration completes.
- Cancelled partially opened realtime provider sessions when connection setup fails before switching to batch transcription fallback.
- Restored an originally empty clipboard after automatic paste when transcript retention is disabled, instead of leaving the temporary transcript behind.
- Failed explicitly when a user-selected microphone is unavailable instead of silently recording from a different input device.
- Reported Keychain read and final auto-save failures instead of presenting inaccessible credentials as missing or silently discarding persistence errors.
- Made Escape cancellation use a dedicated global shortcut channel that is independent from dictation-hotkey registration, with an app-local fallback when global monitoring is unavailable.
- Refined the compact dictation capsule hierarchy with the monochrome Mouthpiece mark, a denser full-width waveform, stronger quiet-speech response, and a more neutral adaptive glass surface.
- Stopped truncated Whisper and Parakeet files or incomplete Qwen Hugging Face caches from being reported as installed local models.
- Surfaced global hotkey registration failures and updated active shortcut descriptors without unnecessarily recreating their event taps.
- Serialized dictionary persistence, made normalized settings the authoritative terminology source, and reconciled stale database mirrors during startup.
- Preserved the visible transcription history and reported persistence failures when history reads or mutations fail instead of silently showing an empty or stale result.
- Prevented delayed local-model status and installation callbacks from overwriting the UI after the user selects a different provider or model.
- Prevented custom provider API keys from being sent to remote plaintext HTTP endpoints while retaining HTTP support for loopback development services.
- Stopped cancelled or superseded dictation sessions from continuing post-processing side effects, including clipboard updates, history writes, and stale failure publication.
- Propagated SQLite row-reading failures instead of returning partial history, dictionary, or migration metadata as successful query results.
- Closed debug log file handles on every write exit path, including seek and write failures.
- Removed the microphone input tap and converter state when `AVAudioEngine` fails to start, keeping the next recording attempt from inheriting a stale tap.
- Applied the user-selected Soniox realtime model when configuring its WebSocket session instead of always sending `stt-rt-v4`.
- Routed Escape cancellation through the same global CGEvent tap as the dictation hotkey, with an app-local fallback when the tap is unavailable.
- Expanded the capsule waveform across its full content width, improved quiet-speech motion, refined the adaptive glass surface, and prevented another Mouthpiece process from being shown as the target application.
- Terminated local model installation commands promptly when their parent task is cancelled.
- Terminated newly launched local model servers when startup is cancelled or fails before registration.
- Ensured Soniox batch uploads are deleted when transcription task creation fails.
- Stopped retrying and logging every audio frame after a realtime provider send failure, while retaining recorded audio for batch transcription fallback.
- Prevented duplicate legacy terminology mappings, including keys that differ only by surrounding whitespace, from crashing settings migration or normalization.

### Added

- Added Volcengine Doubao Streaming ASR 2.0 as an independent realtime-only transcription provider with API Key authentication, incremental utterance updates, and a dedicated control-panel option.
- Added independent controls for automatically inserting completed transcripts and retaining them in the system clipboard.
- Added an option to pause the active system media session during dictation and resume it after stop, cancellation, failure, or shutdown.
- Added a complete macOS 26 control panel and onboarding redesign specification covering information architecture, cool-tinted lightweight Glass navigation, near-white content surfaces, page-level interactions, accessibility, compatibility, implementation phases, and acceptance criteria.
- Added six task-focused native control panel pages with shared settings components, inline credential and model states, shortcut capture, processing previews, searchable history with Undo, and explicit audio and transcript data-path summaries.
- Added a pure native Swift macOS application with an official macOS 15 Sequoia and macOS 26 Tahoe compatibility matrix, SwiftUI control panel and onboarding, an AppKit cross-Space dictation capsule, AVFoundation audio capture, CGEvent hotkeys, Accessibility text insertion, Keychain credentials, SQLite history, and Sparkle updates.
- Added native realtime transcription for Bailian, Deepgram, Soniox, and AssemblyAI, OpenAI-compatible batch transcription, and local Whisper, Parakeet, and Qwen ASR MLX runtimes.
- Added a native dual-architecture release pipeline that verifies the stable self-signed certificate and Designated Requirement, signs Sparkle archives, publishes GitHub Releases, and updates the Homebrew tap automatically.
- Added isolated data-root, preferences, migration, and updater launch controls for native UI automation without reading a developer's live settings, history, models, Keychain entries, or Sparkle choices.
- Added speech activity gating with pre-roll, 20 ms PCM framing, provider protocol replay fixtures, a 10-minute audio processing benchmark, and macOS 15/26 CI coverage.

### Changed

- Reworked onboarding into required Welcome, Permissions, Shortcut, and Capsule Check steps; removed provider setup and network transcription from first-run setup, restored the first incomplete step, and opened Dictation Models after completion.
- Made the Accessibility onboarding card export the real Mouthpiece app bundle as a native file drag item, while requiring both microphone and Accessibility authorization before continuing.
- Added an isolated microphone-and-capsule onboarding check driven by the selected shortcut or Escape, with live audio levels and no transcription, history, clipboard, or insertion side effects.
- Renamed Privacy & Diagnostics to Permissions & Diagnostics and added an always-visible drag guide that opens the macOS Accessibility settings and accepts the real Mouthpiece app bundle.
- Reduced the dictation capsule from 520 points to 280 points wide, introduced compact state-specific heights, and replaced the heavy gray surface with a lighter adaptive glass treatment.
- Reduced native switch sizing throughout the control panel, changed translation activation to the dictation modifier plus a configurable extra key, and refined the shared brand icon as a closed mouse outline with a raised five-bar M waveform.
- Tightened the onboarding sidebar's top spacing so the brand and setup steps sit closer to the window controls.
- Simplified Prompt Studio into Edit and Test tabs, replaced the simulated test runner with real dictation into a native placeholder editor, and surfaced the configured shortcut in the testing workflow.
- Replaced generic waveform branding in the control panel sidebar and macOS menu bar with a shared template-aware Mouthpiece mouse mark.
- Redesigned the dictation capsule as a fixed bottom-center overlay with target and Mouthpiece app identities, a full-width live audio waveform, and a smoothly rolling two-line realtime transcript.
- Standardized remote service configuration as API key followed by model name, matched both field widths, and added a reveal control to masked API key fields.
- Renamed the dictation location control to Transcription Engine, replaced the cloud provider menu with an icon-based provider grid, and reordered cloud setup as API key, model, then realtime transcription.
- Standardized every binary control panel setting on the native macOS switch style and redesigned shortcut selection as an aligned preset menu with confirm-before-save custom key capture.
- Moved microphone and Accessibility permission management from General Settings to Privacy & Diagnostics while preserving onboarding authorization.
- Simplified Privacy & Diagnostics to native debug logging, manual update checks, and version information, removing secondary data-path and sensitive-app controls from the page.
- Replaced the split history browser with a single card list showing each record's timestamp, processed text, original text, dedicated copy actions, and delete action.
- Simplified Vocabulary & Rules into a single Dictionary for preferred names and terms, and removed avoided-term and replacement-rule behavior from text processing.
- Made API key fields save automatically without a separate button and rendered text cleanup and post-dictation translation controls as native macOS switches.
- Replaced generic AI provider symbols with bundled brand icons, moved custom cleanup instructions beside the AI service configuration, and removed the standalone processing test action.
- Aligned control panel inputs by their visible trailing edges, localized all sound preset names, and replaced the hidden cleanup-provider menu with a visible responsive provider selector and provider-specific configuration.
- Reorganized control panel navigation into General Settings, Dictation Models, Text Processing, Vocabulary & Rules, History, and Privacy & Diagnostics, using a lightweight cool-tinted system sidebar and quieter near-white content surfaces.
- Unified control panel and onboarding typography, spacing, row structure, three-language copy, conditional settings, empty states, and window sizing at 1040 × 700 and 820 × 600 respectively.
- Raised the minimum supported system to macOS 15 Sequoia and limited formal compatibility validation to macOS 15 and macOS 26 Tahoe.
- Replaced the Electron, Chromium, React, Node.js, Vite, Tailwind, and electron-builder application stack with a macOS-only Xcode project.
- Corrected XcodeGen resource declarations so the app bundle includes its icon and English, Simplified Chinese, and Traditional Chinese localization tables.
- Preserved dedicated main-dictation and translation activation, 12 sound cue presets, terminology, custom prompts, raw transcript history, sensitive-app policy, and local model cache paths in the native application.
- Migrated legacy settings to UserDefaults and API keys to Keychain, with automatic backup and import from Mouthpiece, OpenWhispr, and VoiceInk data directories.
- Changed local model discovery to reuse both Mouthpiece and legacy OpenWhispr cache paths in place without moving or re-downloading existing models.
- Hardened native releases with locked SHA-1/SHA-256 certificate fingerprints, exact Designated Requirement comparison, nested-code verification, DMG integrity checks, architecture checks, and launch smoke tests.

### Removed

- Removed local GGUF text processing, its model manager and llama runtime, while keeping local model downloads available for dictation.
- Removed Windows and Linux builds, helpers, packaging, CI jobs, platform documentation, and all cross-platform runtime dependencies.
- Removed the legacy JavaScript and TypeScript test suite after replacing its supported macOS behavior with native Swift tests.

### Fixed

- Prevented the realtime microphone regression test from crashing when AVFoundation delivers more than one valid audio frame.
- Corrected capsule target-app fallback, switched its brand identity to the monochrome Mouthpiece mark, expanded and smoothed the live waveform, and made Escape cancellation independent from dictation hotkey restarts.
- Registered Accessibility requests through the macOS trust prompt, followed only the visible Privacy & Security window across displays, and replaced the ineffective duplicate-app drag action with direct switch guidance.
- Reserved a dedicated trailing accessory area in API key fields so masked credentials no longer overlap the reveal button.
- Automatically dismiss dictation failure capsules after a short delay without allowing an older failure to close a newer session.
- Kept custom shortcut capture listening after modifier-key events so combinations such as Command+Shift+K are recorded instead of stopping at the first key.
- Removed the unnecessary divider from the single-row cloud transcription engine section and right-aligned its cloud/local selector.
- Increased light-mode separation between the window, settings groups, provider cards, and history cards; isolated the sidebar glass from desktop wallpaper; and replaced the solid system-blue navigation selection with a softly tinted gradient and highlighted icon.
- Restored the full-color Gemini and Alibaba Cloud provider icons in the native AI service selector while preserving providers whose official marks are monochrome.
- Restored visible section and provider-card surfaces in dark mode and reduced the sidebar's blue and cyan glass tint so the navigation stays visually integrated with the content area.
- Restored the 12 distinct synthesized start and stop sound presets from the legacy app instead of approximating their names with unrelated macOS system alert sounds.
- Kept the control panel usable with a 1000-point minimum width and 600-point minimum content height, while allowing settings pages to expand with the window instead of leaving a fixed-width blank region.
- Prevented recording from crashing on the first audio frame by creating the AVAudioEngine tap callback outside MainActor isolation.
- Preserved custom provider model and endpoint values when switching services, refreshed shortcut names immediately after changing the interface language, and restored the control panel's full working size after onboarding.
- Recovered stale native migration locks after an interrupted launch while preserving the lock when another Mouthpiece instance is actually running.
- Prevented local model installation commands from blocking when long-running package managers produce more output than an unread pipe can hold.
- Preserved upstream dynamic-library compatibility symlinks when assembling Whisper, sherpa-onnx, and llama.cpp runtimes so bundled executables resolve their `@rpath` dependencies at launch.
- Disabled host-specific GGML compilation in release runtime builds so Intel artifacts can be cross-compiled on Apple Silicon and both architectures remain portable across supported Macs.
- Restored Xcode's ad-hoc Debug signing so native test hosts and local preview builds remain launchable, while release archives remain explicitly unsigned until stable signing.
- Kept local XCTest products in Xcode's default DerivedData location, avoiding test-runner hangs when the repository itself is inside macOS's protected Downloads directory.
- Made migration completion markers recoverable when the marker, backup, or copied history database is missing or invalid.
- Rebuild native hotkey and microphone state after wake or app activation, reposition a visible capsule after display recovery, and close realtime connections and local model processes before sleep or application termination.
- Prevented realtime audio from being sent before Soniox or AssemblyAI is ready, extended Bailian's one-time stale-socket replay to cold connections, and cleared buffered audio between sessions.
- Kept recording and retained PCM for same-provider batch fallback when a realtime connection cannot be established, independent of the local-to-cloud fallback preference.
- Moved conversion and RMS work out of the AVAudioEngine realtime callback, bounded queued audio, rejected no-speech recordings, and serialized stop/finalize state by session ID.
- Made legacy import single-instance, allowlisted, versioned, read-back validated, and rollback-safe for settings, Keychain credentials, and copied SQLite files.
- Preserved a captured Accessibility focus target, distinguished permission denial from a busy application, and stopped clipboard restoration from overwriting a user's newer clipboard contents.
- Completed AssemblyAI setup in onboarding, exposed custom transcription endpoints, isolated capsule-position preferences during automation, and added executable coverage for seven-day debug-log retention.

### Documentation

- Reworked the Chinese and English READMEs into user-focused project pages with branded presentation, release and platform badges, a product overview, core features, installation guidance, quick-start instructions, a combined native control-panel and onboarding hero screenshot, and MIT license information.
- Added the complete macOS-only Swift native rewrite plan, including repository cleanup, feature parity, existing data compatibility, exact self-signed Designated Requirement continuity, native updates, testing, and merge-to-main release gates.
- Updated the Chinese and English project guides, native release acceptance checklist, release-note rules, and bilingual v2.0.0 user notes to match the final macOS-only feature set.

## [1.4.8] - 2026-07-02

### Fixed

- Bailian realtime transcription now uses the Qwen-ASR recommended server VAD threshold and 400 ms silence endpoint, improving quiet-speech pickup and reducing the wait for completed turns.
- Live transcript text now enters and follows incoming partial results more quickly while preserving the existing capsule layout and visual treatment.

### Internal

- Updated stale realtime provider and live-preview wiring assertions to match the current lazy provider loading and primitive transcript props.

## [1.4.7] - 2026-06-30

### Fixed

- On macOS, the dictation capsule now moves to the display under the pointer before it is shown while preserving its dragged position when it is already on that display, preventing successful recordings from appearing to have no capsule in multi-monitor setups.

### Internal

- Agent instructions now live primarily in `AGENTS.md`, with `CLAUDE.md` delegating to it and release note writing rules documented in `Release_Notes_Guidelines.md`.

## [1.4.6] - 2026-06-20

### Fixed

- Debug log pruning now deletes `debug-*.log` files older than 7 days instead of 14 days when debug logging initializes.
- Bailian realtime warm connections now expire after a short idle window and retry once with the first PCM frames replayed if the reused socket produces no server events, preventing stale first recordings from timing out or surfacing intermittent `Connection lost (code: 1006)` errors.
- Bailian realtime dictation no longer intermittently waits for the session timeout and falls back to batch transcription when recording begins before the main-process helper or WebSocket session is ready. Pre-start PCM frames now create the realtime helper on demand, survive session-state reset, and flush after the configured socket attaches.

### Internal

- Release Windows builds now pin the GitHub Actions runner to `windows-2022`, avoiding VS2026/node-gyp native dependency rebuild failures during `npm ci`.

## [1.4.5] - 2026-06-04

### Added

- 12 dictation sound effect presets (Classic, Retro Arcade, Bubble Pop, Sci-Fi, Marimba, Playful Bounce, Robot, Gentle Chime, Typewriter, Coin Collect, Laser Zap, Whistle) selectable from Settings > Sound Effects, all synthesized via Web Audio API with zero bundle size impact.
- Preview button in settings to audition each sound preset before selecting it.

### Fixed

- Bailian (DashScope) realtime transcription no longer intermittently silently falls back to the batch model. The renderer used to start streaming audio before the main-process WebSocket handshake had completed; any leading audio frames were dropped because the buffering branch only kicked in once the socket existed. With nothing reaching server-side VAD, the realtime turn never committed and the empty-text fallback at the end of the take demoted to qwen3-asr-flash. Audio is now buffered through the cold-connect window and replayed as soon as the session attaches.
- Bailian realtime warm connection now schedules a single best-effort re-warm after a server-side idle close, so the next dictation does not pay full cold-connect latency.
- The streaming → batch fallback is now logged at warn level (was info) so the silent demotion is more visible in debug logs.
- Cleanup model no longer "answers" questions or follows commands found inside the dictated transcript. The transcript is now wrapped in an explicit `<transcript>...</transcript>` delimiter and a high-priority safety guardrail is injected at runtime into every assembled system prompt (routed to a Chinese or English version per UI language), telling the model to treat tag contents as untrusted data and to return question-shaped input verbatim instead of answering it. Because the guardrail is runtime-injected (not baked into the prompt body), users who carry over a saved custom cleanup prompt from a prior version are also protected — previously a saved custom prompt would have overridden the new default and bypassed the guardrail entirely. Closing tags inside user content are escaped before wrapping to prevent boundary forgery. Applied across OpenAI (Responses + Chat Completions), Bailian, Custom OpenAI-compatible, Groq, Anthropic, local llama.cpp, and Mouthpiece cloud paths.
- Gemini specifically was the most fragile injection vector — system prompt and transcript were being concatenated into a single user-role text part with no role split. The Gemini path now uses the official `system_instruction` field plus a separate user part, so the model has structural cues that the second half is data rather than further instructions.

## [1.4.4] - 2026-05-27

### Fixed

- AI translation language selector now defaults to "en-US" (English US) instead of a bare "en" that did not match any dropdown option, so new users see the correct "English (US)" label and the option is properly highlighted on first enable.

### Changed

- Reduced macOS paste latency: the pre-paste wait is now a clipboard-ready poll (capped at 50ms) instead of a flat 120ms sleep, so dictation results land in the target app roughly 100ms sooner on the common path.
- Streaming dictation finalize now waits 80+220ms (was 120+300ms) between key release and provider finalize, shaving ~120ms off the end of every streaming take while keeping both safety waits intact.
- MediaRecorder now records as audio/webm;codecs=opus at 32 kbps (with feature-detect fallback) and emits 100ms chunks via start(100), so blobs are ~3× smaller and the recorder's onstop fires faster because the last chunk is already encoded.
- Control panel window controls react to maximize/unmaximize events directly instead of polling the main process once per second, removing ~86k idle IPC calls per day per open control panel.
- The reasoning model selector's GPU status badge pauses its 5-second background poll while the window is hidden (minimised / background), so no idle IPC traffic runs against the local llama-server when the user isn't looking at the panel.
- Dictation capsule now memoises its per-frame visual state, layout calculations, and the four live-preview style objects, so the audio-rate parent re-render no longer re-allocates layout output and inline style literals every frame.
- App.jsx now uses useCallback for the seven mouse / focus handlers it passes to the floating dictation capsule, so the memoised capsule actually skips re-renders when only sibling state changes.
- Dictation capsule now consumes live-preview text as two primitive string props (livePreviewActiveText + livePreviewFullText) instead of a fresh object literal every audio frame, so React.memo's shallow comparison can finally short-circuit when the actual text hasn't changed.
- Control panel memoises the updater banner action object and stabilises the sidebar / history "open settings" / "open referrals" callbacks, so toggling the update banner no longer cascades into a sidebar + history re-render.
- Transcription model picker now memoises its cloud provider tab list and discovers cloud models when any one API key actually changes (collapsed into a single fingerprint dependency) instead of whenever React reruns the effect with referentially-different but value-identical inputs. Also removes a no-op useMemo wrapper.
- Slimmed the Google Fonts request from 10 Noto Sans variants (italic 300/400/500/600/700 + upright 300) down to the 4 upright weights actually used in CSS (400/500/600/700), cutting first-paint font payload by roughly 150-250 KB.
- Vite renderer build now targets esnext (Electron 36 / Chromium 124+ supports ES2022+ natively, so the down-compile helpers are no longer needed) and pre-bundles react / react-dom/client / i18next / react-i18next via optimizeDeps.include for faster cold dev start.
- i18n preload no longer re-loads the English bundle when a non-English locale is selected (English resources are already seeded inline), saving one redundant backend init step on startup for non-English users.
- Compressed `src/assets/icons/providers/llama.svg` via svgo multipass (precision=2), trimming ~1.6 KB (~27%) off the largest provider icon.

### Internal

- Removed two unused runtime dependencies (`object-assign`, `shadcn-ui`) from package.json; `object-assign` remains as a transitive dependency only, and `shadcn-ui` is the CLI scaffolder which doesn't need to ship with the app.
- Dropped the `APP_REASONING_POLICY_PATTERNS` manualChunks grouping in vite.config.mjs so Rollup can tree-shake `prompts.ts` and its siblings into the chunks that actually need them, instead of being force-pinned into a single large `app-reasoning-policy` chunk that the eager audio pipeline import pulled into the initial graph.
- The `set-debug-logging` IPC handler now reads and writes the userData `.env` file via fs.promises instead of fs.readFileSync/writeFileSync, so toggling debug logging from Settings no longer briefly blocks the Electron main thread.
- Replaced raw `console.log` calls in dragManager (per-drag start/stop) and modelDirUtils (cache migration) with debugLogger so they respect the configured log level instead of always firing in production.
- Local whisper-server upload no longer Buffer.concats the full multipart body before req.write — it now writes each segment directly, eliminating one ~WAV-sized buffer allocation per local Whisper transcription.
- Local whisper / Parakeet decode-and-resample step (`decodeAudioBlobToMono16kSamples`) now reuses the long-lived 16 kHz AudioContext we already keep for the streaming pipeline instead of spinning up a fresh AudioContext per call, and drops a no-op `arrayBuffer.slice(0)` copy — shaving 20-60ms off every local-model dictation.

### Fixed

- Debug log directory now self-prunes on each app launch — only the 20 most recent debug-*.log files are kept, and anything older than 14 days is deleted regardless of count. Previously the directory grew forever (one new file per launch), eventually consuming significant userData disk space.
- UI language switching now loads non-English locale bundles correctly, so selecting Simplified Chinese in Settings updates the control panel instead of falling back to English.
- The UI language selector now renders flag emoji with an explicit emoji font fallback, fixing the Traditional Chinese flag display on Electron/Chromium builds where the app font intercepted regional-indicator glyphs.

## [1.4.3] - 2026-05-24

### Added

- AI Translation Output: enable it in Settings → AI Models → AI Translation Output, pick a target language, then set a dedicated "Translation hotkey" in Settings → Hotkeys → Translation hotkey. The main dictation hotkey stays cleanup-only; the translation hotkey runs transcribe + cleanup + translate against the same provider / model in a single LLM call. The two hotkeys have a clean semantic split — there is no manual placeholder for the main hotkey to opt into translation.
- Translation-mode capsule badge: while a dictation session was triggered by the translation hotkey, the floating capsule shows a small blue pill with the target language ISO code (EN / ZH / JA…) so you can tell at a glance which mode this take is in.
- History items now disclose the raw transcript (pre-cleanup / pre-translation) on demand via an expandable "View raw transcript" toggle. Legacy items without a recorded raw transcript continue to show only the final text.
- Translation failure fallback: when the cleanup + translate LLM call fails (network, quota, etc.) the original transcript is pasted and an inline toast notifies the user. Only fires when translation is enabled.

### Changed

- Main and translation hotkey inputs are now guided rather than free-form. The main dictation hotkey input in Settings → Hotkeys and in Onboarding only exposes the "Modifier only" shortcut type, and the translation hotkey input only exposes "Key combo" with the modifier prefix pinned to whatever the main hotkey uses (e.g., if main is Globe, the translation modifier chip is locked to Globe and only the primary key is editable). This replaces the previous flow where users could pick an obviously-invalid combination and only learn about it from a post-hoc validation warning. The Globe / Fn key is now also recognised as a modifier for prefix-matching, so a Globe-only main hotkey can finally produce a valid `Globe + K` style translation hotkey.

### Fixed

- macOS users whose main dictation hotkey is the default Globe / Fn key no longer see a spurious "Hotkey must be modifier-only" warning when they re-confirm the same Globe choice in the Settings → Hotkeys → Main dictation hotkey input. The hotkey validator now treats Globe / Fn as a modifier-only token, matching how the native push-to-talk listener already handled it.
- Translation hotkey now actually fires when the main hotkey uses a token Electron's `globalShortcut` doesn't accept. Previously the translation chord was routed through `globalShortcut.register`, which silently refuses Globe-prefixed accelerators (e.g., `Globe+K`) on macOS and modifier-only-prefix combos that confuse its parser; the registration succeeded in the renderer's eyes but no keypress ever reached the handler. On macOS the chord is now detected by the existing native Swift listener (`resources/macos-globe-listener.swift`), which emits the held modifiers + primary key on every keyDown and is matched against the stored translation accelerator inside `main.js`. On Windows a second native key-listener child process (started via `windowsKeyManager.startTranslation`) handles the chord with the same tap-to-toggle semantics. Either listener aborts any in-flight push-to-talk session before firing the translation toggle, so a Control-held → K-pressed (or Globe-held → K-pressed) sequence no longer starts both the main dictation and the translation flow in parallel.
- Translation hotkey no longer surfaces the primary key as an IME candidate on macOS. Previously when the translation hotkey (e.g. `Right Shift + X`) fired, the Swift Globe listener tap ran in `.listenOnly` and merely observed the keyDown, so the OS kept propagating it to the active app — a Chinese input method would helpfully pop up an "X" candidate even though the chord had already been routed into the translation pipeline. The tap now runs in `.defaultTap` so its callback can return `nil` to swallow matched events. A new background stdin reader in `resources/macos-globe-listener.swift` accepts `SET_TRANSLATION_CHORD:<chord>` / `CLEAR_TRANSLATION_CHORD` lines pushed by `globeKeyManager.setTranslationChord()` (called from `main.js` whenever `applyTranslationHotkey` runs), so the listener always knows which exact chord to swallow. The chord is also cached in `globeKeyManager` before spawn so if the renderer publishes it before the listener is up, it gets flushed as soon as stdin is available. Modifier-only main hotkeys are unaffected because they don't carry a primary key and never match the swallow branch.
- AI Models dropdown in Settings → Smart no longer gets sandwiched beneath the AI Translation card. Every `.settings-group` panel creates its own stacking context via `backdrop-filter: blur(...)`, so the in-tree absolutely-positioned `SearchableModelSelect` popover was being clipped behind whichever sibling group rendered later — most visibly the AI Translation card sharing the same page. The dropdown now renders via `createPortal(..., document.body)` and positions itself with `position: fixed` against the trigger button's `getBoundingClientRect()`; a `useLayoutEffect` keeps the anchor in sync on scroll/resize, and click-outside detection now checks both the trigger container and the portalled popover. The portal sits outside every settings-group stacking context so the popover's z-index finally wins.
- Dev startup and packed-app launch no longer hang when fonts.googleapis.com is slow or unreachable. `src/index.html` was loading the Noto Sans stylesheet as a render-blocking `<link rel="stylesheet">`, which kept `window.onload` waiting — and Electron's `did-finish-load` along with it. In dev that meant the renderer never signaled ready and `startApp`'s `await loadURL(...)` sat there indefinitely on networks where Google Fonts is throttled (corporate VPN, restricted regions). The link is now `rel="preload" as="style"` with an `onload="this.onload=null;this.rel='stylesheet'"` swap so the font request is non-blocking; a `<noscript>` fallback preserves the stylesheet for JS-disabled environments.

### Removed

- Dead code cleanup: `src/components/ui/MarkdownRenderer.tsx` and its sole dependency `react-markdown` (~10 KB min+gzip plus the chunk-splitting boilerplate in `src/vite.config.mjs`) had no callers anywhere in `src/`. The unused `src/assets/mouth-top.jpg` source-artwork stub (mentioned only in `src/assets/README.md`) is gone too. Drops one renderer-chunk pattern from the bundle, one transitive dep graph (`react-markdown` pulls in `remark-*`/`rehype-*`/`unified`/`micromark` — collectively ~100 KB min+gzip if Rollup ever decided not to tree-shake them) from `package.json`, and one stray asset from the source tree.

### Internal

- Renderer preload no longer pays a synchronous IPC round-trip at startup to fetch runtime config (`apiUrl` / `authUrl` / `enableMouthpieceCloud` / `oauth*`). Previously every renderer (Main dictation window + Control Panel) called `ipcRenderer.sendSync("get-runtime-config-sync")` inside `preload.js` before any renderer JS ran, blocking both processes for the round-trip. The config is now built once in a new `src/helpers/runtimeConfig.js` module and injected into each window via `webPreferences.additionalArguments` (`--runtime-config=<json>`); `preload.js` parses that argv entry instead. The async `ipcMain.handle("get-runtime-config")` fallback stays for any out-of-band caller, and the helper functions (`getApiUrl`, `getAuthUrl`, etc.) used throughout `ipcHandlers.js` are now thin re-exports of the shared module so behavior is unchanged for downstream callers.
- Faster app startup by trimming `main.js` (a) the unconditional `await new Promise(r => setTimeout(r, 500))` that ran on every dev launch is removed — `DevServerManager.waitForDevServer()` (already invoked by `loadMainWindow` / `loadControlPanel`) handles dev-server gating, the 500 ms buffer was dead weight; (b) `createMainWindow` and `createControlPanelWindow` now run via `Promise.all` instead of sequential `await`, so the control panel's HTML load no longer pushes the main dictation window's "ready-to-show" later; (c) `WindowManager.createMainWindow` no longer awaits `initializeHotkey()` — hotkey init (reads persisted hotkey, `globalShortcut.register`, spawns the native push-to-talk listener) runs as fire-and-forget after `loadMainWindow` succeeds, with a `.catch` that logs to debug telemetry. UI shows up sooner; hotkey arms in the background.
- Provider-specific and platform-gated manager modules are no longer `require()`d at top of `main.js`. Previously `ParakeetManager`, `QwenAsrManager`, `UpdateManager`, `WhisperCudaManager`, `WindowsKeyManager`, `MacOSPermissionFlowManager`, and `GlobeKeyManager` were all parsed (along with their transitive deps — `parakeetServer` + sherpa-onnx wrapper, `qwenAsrServer` + mlx asr glue, `electron-updater`, model registry JSON, etc.) at the synchronous top-level of `main.js`, before `app.whenReady`. They're now required inside the function that instantiates them: provider managers + Windows/Mac key managers inside `initializeCoreManagers()`, `GlobeKeyManager` inside `initializeDeferredManagers()` (which only runs after windows are visible). `WhisperCudaManager`'s require is also platform-gated alongside its existing `process.platform !== "darwin"` instantiation guard. Public behaviour is unchanged — the manager instances still exist before any IPC handler can call them — but cold-start parse work is pushed past the first paint.
- Streaming-provider classes in `src/helpers/ipcHandlers.js` (`AssemblyAiStreaming`, `DeepgramStreaming`, `QwenRealtimeStreaming`, `SonioxStreaming` — each pulls in the `ws` WebSocket client plus the provider-specific glue) are no longer eagerly required at module load. They're wrapped in a `Proxy({}, { construct })` that calls `require()` on the first `new`, then caches the resolved class. Callers (`new AssemblyAiStreaming()`, etc.) are unchanged, but a renderer using only one streaming provider now only parses that one library at startup instead of all four.
- `src/helpers/database.js` no longer re-prepares the same SQL on every call. Every `saveTranscription` / `getTranscriptions` / `clearTranscriptions` / `deleteTranscription` / `getDictionary` / `setDictionary` invocation previously rebuilt its `db.prepare(...)` statement, plus `setDictionary` re-prepared the `DELETE` + `INSERT OR IGNORE` pair inside its transaction closure each call. Statements are now prepared once during `initDatabase()` and cached on `this.stmts.*`; the dictionary replacement transaction is also pre-bound (`this.replaceDictionaryTxn`) so the hot path on every dictation is one `.run()` against an already-prepared statement. Added `CREATE INDEX IF NOT EXISTS idx_transcriptions_timestamp ON transcriptions(timestamp DESC)` since the History list hits `ORDER BY timestamp DESC LIMIT ?` and was previously doing full-table scan + sort once the row count grew. Public method signatures are unchanged.
- Three micro-opts on hot IPC + reasoning paths. (a) `IPCHandlers` constructor now caches `this.appVersion = app.getVersion()` instead of calling `app.getVersion()` six times per cloud-transcribe (`appVersion` + `clientVersion` × 3 branches) plus once per get-version request. (b) `src/models/ModelRegistry.ts` memoizes `getAllReasoningModels()` (the flat array stops getting `flatMap`+`map`-rebuilt per call) and adds an O(1) `value→model` Map lookup that `getReasoningModelLabel` and `getModelProvider` now use instead of `Array.find`. `REASONING_PROVIDERS` is already a module-load constant so the cache is safe. (c) `ipcHandlers.js` replaces the 15+ inline `require("./modelManagerBridge").default` and `require("../services/localReasoningBridge").default` calls in IPC handler bodies with two lazy module-level getters (`getModelManagerBridge()` / `getLocalReasoningBridge()`) — preserves the lazy-on-first-use semantics but skips the per-call module-cache `Map.get`.
- Pending-timer leak fixes. `src/helpers/globeKeyManager.js`'s auto-restart `setTimeout` (fires after a Globe-listener exit with code 0, i.e. event-tap invalidated by sleep/wake) was never stored, so `stop()` couldn't cancel a pending restart. Rapid stop/start cycles (settings save, sleep/wake combos) could stack multiple pending callbacks even though the `_isStopping` guard prevented the spawn. The id is now tracked on `this._pendingRestartTimer` and cleared in `stop()`. `src/helpers/windowManager.js`'s 1 s control-panel crash-recovery `setTimeout` was similarly untracked — if `cleanup()` / app quit ran inside that window the timer fired against a destroyed `controlPanelWindow`. Now stored on `this._controlPanelRecoveryTimer` and cleared on `controlPanelWindow.on("closed")`. `main.js` runtime-fingerprint write switches from `fs.writeFileSync(fingerprintPath, ...)` to `fs.promises.writeFile(...).catch(() => {})` since the fingerprint is observability-only and nothing on the startup path waits for it — keeps the synchronous startup tick free.
- `src/helpers/whisperServer.js` no longer transcodes every dictation through FFmpeg unconditionally. The renderer's voice-gate / batch path produces 16 kHz mono WAV via `samplesToWavBlob`, but `transcribe()` was always calling `_convertToWav()` — paying FFmpeg's startup (~100–200 ms) + the temp-file write/read round-trip even when the buffer was already in the exact format whisper.cpp wants. A new RIFF/WAVE header check (the same `isWavFormat` helper from `ffmpegUtils` that `parakeetServer._ensureWav` already uses) short-circuits the conversion when the input is already WAV. Non-WAV inputs (raw webm/opus from MediaRecorder) still fall through to FFmpeg as before.
- Hot-path temp-file I/O in `whisperServer._convertToWav` and `parakeetServer._ensureWav` no longer blocks the Node event loop. Each transcription was previously doing `fs.writeFileSync(audioBuffer)` → FFmpeg → `fs.readFileSync(wav)` → `fs.unlinkSync()` synchronously, stalling every other IPC handler for the duration of the disk I/O (10–80 ms per dictation, more on slow disks). All three operations now use `fs.promises.writeFile` / `readFile` / `unlink`; `parakeetServer._cleanupFiles` becomes `async` and parallel-unlinks via `Promise.all` (silently swallowing `ENOENT` and logging other errors as before). `parakeetServer` callers `await` cleanup so temp files don't leak past the `try`/`finally`. Behavior is otherwise unchanged — same temp file paths, same FFmpeg conversion call, same return shape.
- `src/helpers/debugLogger.js`'s `log()` / `error()` / `fatal()` variadic methods now short-circuit on `shouldLog(level)` before running `formatArgs(args)`. Previously every call ran `formatArgs` (JSON.stringify on each object arg) and then asked `write()` to drop the entry — so info-level production builds were still paying the serialization cost for every debug-level call site (and `ipcHandlers.js` calls these 4× per transcribe). The reordered guard skips the `JSON.stringify` cycle entirely when the level is filtered out. `debug()`/`info()`/`warn()` were already cheap (no formatArgs), so they're unchanged.
- Renderer-side `src/utils/logger.ts` no longer pays an `await electronAPI.getLogLevel()` + `await electronAPI.log(...)` IPC chain on every call. `audioManager.js` calls `logger.info/debug` ~120× per dictation; each one previously suspended the microtask queue twice (level fetch + log write), blocking other renderer work and adding structured-clone cost. The log level is now cached synchronously (seeded with `defaultLevel = "info"`, upgraded once when `getLogLevel()` resolves on app start). `log()` returns `void` instead of `Promise<void>`, runs `shouldLog` against the synchronous cache, writes to console immediately for DevTools visibility, and fire-and-forgets the main-process IPC forward via `Promise.resolve(...).catch(() => {})` so the on-disk debug log still captures level-passing entries but the caller is no longer blocked. Pre-cache callers during the brief startup window before the IPC level resolves simply use the conservative default, matching the previous async behavior.
- `src/helpers/qwenRealtimeStreaming.js` `sendAudio()` builds its 50 Hz `input_audio_buffer.append` event via direct template-literal string concatenation instead of `JSON.stringify(buildAppendEvent(...))`. The Bailian realtime API receives ~50 frames per second per dictation; each `JSON.stringify` call was allocating an intermediate object + walking keys + escaping values even though the only dynamic fields are the event_id (UUID / `event_<ts>_<rand>` — ASCII safe) and the base64 audio payload ([A-Za-z0-9+/=] — never needs JSON escaping). The new template literal keeps `JSON.stringify(eventId)` for safety, drops the object construction, and is otherwise byte-for-byte compatible. `buildAppendEvent` remains for non-hot callers.
- `src/hooks/useAudioRecording.js`'s ~300-line setup effect no longer tears down and re-registers five IPC listeners + reinitialises the audio manager every time the i18n locale changes. The effect was listing `t` in its dependency array (because nine inline `t("…")` calls inside it triggered exhaustive-deps), so any locale switch forced a full effect re-run — observable as a stutter when changing UI language with the dictation pipeline armed. `t` is now stashed in a `useRef` that's refreshed on every render (`tRef.current = t`); the nine `t(...)` call sites inside the effect become `tRef.current(...)` and `t` drops out of the dep array. The two top-level helper-function call sites (`getFallbackToastDescription`) keep their parameter-based `t` — unchanged because they're not inside the effect.
- `src/components/ui/SearchableModelSelect.tsx` no longer re-renders the portalled dropdown on every scroll tick. The scroll/resize listener used to call `setAnchorRect(getBoundingClientRect())` synchronously on each event, re-rendering the dropdown (and its `filteredModels` list of 50+ items) per wheel notch even though most positions are byte-identical. The listener is now wrapped in `requestAnimationFrame` with a rect-equality check (top/left/width/height) so successive identical rects collapse to no state update. The click-outside / focus-input effect also drops `filteredModels.length` from its dep array — every keystroke in the search input was tearing down the `mousedown` listener and re-scheduling a `requestAnimationFrame(focus)`. Both effects now react only to `isOpen`.
- `src/components/ui/LanguageSelector.tsx` no longer re-measures all 61 labels via `canvas.measureText` on every render with a fresh `options` literal, and the filter loop on every keystroke is now memoized. (a) A module-level `WeakMap<LanguageOption[], number>` caches the computed `contentWidth` keyed by the array reference, so callers passing the same `items` (or two instances sharing a constant array) skip the 61-call measureText loop after the first paint. (b) `filteredLanguages` is wrapped in `useMemo([items, searchQuery, showSearch])` and the search query is lowercased once instead of twice per item. Behaviour and visible layout are unchanged.
- `src/components/DictationCapsule.tsx` extracts the 29-span waveform-bar row into a `React.memo`'d `WaveformBars` leaf. The compact and recording layers each rendered the dots inline via a `.map` with a fresh inline `style` object per span, re-evaluating at the audio-level cadence (~12.5 Hz from `setInterval` in audioManager). The new `WaveformBars` component takes `dots`, `containerClassName`, and the three state-dependent style values (`opacity`/`background`/`boxShadow`) as props; the base style (width / height / transition / transformOrigin) is hoisted to a module-scope object. When `dots` and style props are unchanged frame-to-frame, the memo bails out and the 29 child spans don't re-render. Visible output is byte-identical.
- `src/hooks/useSettings.ts` no longer cascades every Zustand mutation through the `SettingsContext.Provider` to all consumers. Previously `useSettingsInternal` called `useSettingsStore()` (whole-store subscription) and returned a fresh 80+key object literal on every render, so any setter (`setOpenaiApiKey`, `setDictationKey`, `setTheme`, …) re-rendered the entire `SettingsPage` (1461-line tree), `ControlPanel`, `DictionaryView`, `TerminologySettingsCard`, `OnboardingFlow`, and `useTheme` even if they read none of the changed slices. The hook now subscribes via `zustand/react/shallow`'s `useShallow` selector that projects exactly the 80 fields it exposes; React skips re-rendering the hook (and re-emitting context) when none of them changed. The return value is the projection itself (no extra literal allocation), so context-value identity stays stable on no-op mutations. The full `useSettings()` API and consumer call sites are unchanged.
- `src/components/ui/TranscriptionItem.tsx` is now wrapped in `React.memo`. `HistoryView` re-renders on any banner/dismiss toggle, store reload, or settings change (via the same `useSettings` context this PR also optimised) and was re-rendering every transcript row in the process. Each row owns its own `isHovered` / `isCopied` state, so a parent re-render reset hover affordances mid-mouse-move on long history lists. The row's `item` reference is stable (history is an array slice from Zustand), and `HistoryView` already gets `copyToClipboard` / `deleteTranscription` as `useCallback`-stable refs from `ControlPanel`, so the memo's default shallow prop comparison cleanly bails out on no-op parent renders.
- Three heavy children are now `React.lazy`-split out of their host bundles. (a) `SettingsPage.tsx`'s `TranscriptionModelPicker` (~1664 LoC), `ReasoningModelSelector` (~1079 LoC), and `PromptStudio` (~720 LoC) used to ship in the SettingsPage chunk even though users typically open one tab at a time — they're now `lazy(() => import("..."))` with `Suspense fallback={null}` boundaries at each render site. (b) `ControlPanel.tsx` was statically importing `HistoryView` while the peer overlays (`SettingsPage`, `DictionaryView`, `ReferralModal`) were correctly lazy — `HistoryView` (with `TranscriptionItem` + `formatDateGroupParts` in tow) is now lazy too, matching its peers. The four new chunks defer ~110 KB of source from the cold-start render path.
- The renderer no longer ships all 10 UI-language translation JSONs in the entry chunk. Previously `src/i18n.ts` statically imported `TRANSLATIONS_BY_LOCALE` (10 × ~60–85 KB ≈ 530 KB; Russian alone is 85 KB), so a Chinese-only user paid every other locale's bundle weight. The hook now seeds i18next with only English (the smallest, also the fallback) plus a minimal custom backend that dynamic-imports `./locales/<lng>/translation.json` on demand — Vite splits each locale into its own chunk, fetched only when that language becomes active via `preload: ["en", initialLanguage]` or a later `changeLanguage`. The (small, ~2 KB each) prompts JSONs stay eager so reasoning paths don't need to await translation loads. `src/locales/translations.ts` is deleted (no remaining consumers). `tests/translation-i18n-keys.test.mjs` continues passing because it asserts JSON shape directly.
- `src/assets/mouthpiece-icon.png` shrunk from 402 KB at 1024×1024 to 9.5 KB at 96×96 (~97.6% smaller). The capsule renders this icon at `h-8 w-8` (32×32 CSS px), so 96×96 is 3× retina headroom — well past what any current display needs at that size. The original 1024×1024 artwork lives separately in `src/assets/Mouthpiece icon.png` for app-icon builds. `DictationCapsule.tsx` import path is unchanged — same filename, just a smaller bitmap.
- Two more oversized PNGs trimmed: `src/assets/icon.png` from 155 KB at 512×512 to 17 KB at 128×128 (consumers render at `w-11 h-11` / `w-5 h-5` plus index.html favicon — 128 px covers all of them with retina headroom; the Linux tray icon also reads this file but Electron auto-scales menubar bitmaps). `src/assets/icons/providers/deepgram.png` from 172 KB at high-res to 2.5 KB at 64×64 (the only consumer is `providerIcons.ts` for a small chip icon). Same filenames, no import changes.
- Renderer animations now pause when the window is hidden. Six always-on infinite-loop animations driving `filter: blur(...)` (the four `.glass-orb-1..4` orbs at `src/index.css:477,486,495,504`, `.activation-pulse activation-breathe` at `:1481`, and `.referral-mesh-bg::before/::after mesh-drift` at `:2269`) used to keep repainting the whole window even when the Control Panel was sent behind another app — Electron doesn't background-throttle GPU compositing for filter-driven keyframes. A tiny visibility listener in `src/main.jsx` toggles `document.documentElement.dataset.windowHidden`, and a single CSS rule pauses all keyframe animations under `html[data-window-hidden="true"]` via `animation-play-state: paused !important`. Finite animations pause too but resume on next visibility — harmless. Behaviour while the window is visible is unchanged.
- Both READMEs document the new AI Translation Output flow. `README.md` and `README.en.md` were last refreshed before Phase 8/9 shipped and had zero mentions of translation; updated in parallel to keep the bilingual pair aligned. Added one use-case bullet in the "这是什么 / What It Is" section, one feature bullet in "它现在能做什么 / What Mouthpiece Can Do Today", and a dedicated "AI 翻译输出 / AI Translation Output" subsection under "模式与能力 / Modes and Capabilities" that covers how to enable it (Settings → AI Models → AI Translation Output + Settings → Hotkeys → Translation hotkey), the main-vs-translation hotkey split, the capsule's target-language badge, the raw-transcript fallback on translation failure, and the fact that translation reuses the intelligence-layer provider / model with no extra API key configuration.

## [1.4.2] - 2026-05-21

### Internal

- **CLAUDE.md picks up a generic "Behavioral guidelines to reduce common LLM coding mistakes" appendix.** The four-section block (Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution) is dropped in verbatim after the existing Mouthpiece-specific rules so future AI-assistant sessions inherit the same caution-over-speed, surgical-edit, success-criteria stance regardless of which task they pick up. No code, build, runtime, or shipped-binary surface is affected — this only changes how AI tools read the repo.

## [1.4.1] - 2026-05-19

### Fixed

- **Control Panel no longer keeps the GPU busy when hidden or backgrounded.** The Control Panel window was being created with Chromium's background throttling explicitly disabled, so even when the window was hidden or sent behind another app it kept driving the Liquid Glass animations and ambient orb layer at full visible-state rate, showing up as elevated GPU usage on idle machines. `src/helpers/windowConfig.js` no longer sets the throttling opt-out on the Control Panel `webPreferences`, so Chromium can quiet the renderer once the window is not visible. Visible-state styling, animation and visual treatment are unchanged; a regression test in `tests/control-panel-background-throttling.test.mjs` guards against the flag being re-introduced.
- **Dictation capsule now reliably wakes after switching macOS Spaces.** On macOS, jumping between desktops/Spaces and then triggering dictation could leave the capsule stuck on the previous Space — Electron still reported the window as visible, so the wake path returned early, but the panel had not been re-attached to the active desktop and nothing actually showed up on screen. `showDictationPanel` in `src/helpers/windowManager.js` now refreshes the main window's topmost flag and `visibleOnAllWorkspaces` state every time the panel is woken, and re-shows the panel on macOS via a non-focus-stealing path so the wake does not yank focus away from whatever app the user is dictating into. A new regression test covers that the Space refresh happens before any visibility check and that the refresh path does not focus the window.

### Internal

- **README updated to drop the removed auto-learn feature, list the Custom transcription provider, and surface the Homebrew install entry.** `README.md` (Chinese) still had four lingering references to "自动学习" — auto-learn was removed back in v1.2.0 (`chore/remove-auto-learn`), and there are no longer any `auto.?learn` matches in `src/` or the i18n files. The two "What it is / What it does" bullets, the section heading `### 词典、术语与自动学习` → `### 词典与术语`, and the `- 支持自动学习修正结果` bullet are all cleaned up. Both READMEs also missed **Custom** in the cloud transcription provider list — `CLOUD_PROVIDER_TABS` in `TranscriptionModelPicker.tsx` actually ships 7 providers (OpenAI / Deepgram / Groq / Mistral / Soniox / Alibaba Bailian / Custom), not 6, and the order has been realigned to match the code. The "Install or run" section now leads with `brew install --cask notwizard/mouthpiece/mouthpiece` (the `NotWizard/homebrew-mouthpiece` tap is auto-bumped on every release via the existing `release.yml` "Update Homebrew tap" step) and clarifies the Releases entry as macOS DMG / Windows EXE. `README.en.md` mirrors the same changes minus the Chinese-only auto-learn cleanup, since its English copy had already been kept clean.
- **Bumped GitHub Actions to Node.js 24-compatible major versions to clear the June 2026 deprecation.** Across `release.yml`, `build-and-notarize.yml`, `build-windows-fast-paste.yml`, `build-windows-key-listener.yml` and `download-fallback-smoke.yml`: `actions/checkout@v4` → `@v6`, `actions/setup-node@v4` → `@v6`, `actions/cache@v4` → `@v5`, `microsoft/setup-msbuild@v2` → `@v3`. Two action references left intentionally on their current pin: `ilammy/msvc-dev-cmd@v1` (no v2 published upstream yet — still v1.13.0; the deprecation warning will remain for this single action until the maintainer ships a Node 24 release) and `actions/upload-artifact@v4` (not flagged in the v1.4.0 release-run deprecation annotations, kept on v4 to avoid scope creep). No workflow logic, job topology, env, secret, cache key, or step ordering was changed — purely a `uses:` version bump.

## [1.4.0] - 2026-05-19

> Note: Version numbering restarts at `1.0.0` for this standalone Mouthpiece repository. The `1.5.x` entries below are retained as inherited upstream reference only.

### Removed

- **Removed the "Audio quality & false-capture control" panel from Transcription settings — the underlying VAD, capture-constraint and realtime-endpointing values are now hardcoded.** The three user-facing knobs (`audioQualityMode` × 3 modes, `voiceGateStrictness` × 3 levels, `realtimeEndpointingMode` × 3 modes) were either no-ops for the default streaming providers (Bailian streams bypass the local gate entirely) or silently disabled the speech-activity gate (selecting Low latency turned the gate completely off and skipped batch pre-processing), so the panel was a confusing surface that didn't behave the way the labels implied. The settings are now baked in at the historical "Reduce false captures" + "Standard" + "Balanced" combination — the same defaults the panel originally shipped with — because the panel's stated intent was always to prioritize false-record rejection over latency. Removed surfaces: the `AudioQualitySettingsCard` in `SettingsPage.tsx`; the three settings fields, type unions, setters and `updateTranscriptionSettings` plumbing in `settingsStore.ts` and `useSettings.ts`; the per-mode profile table and strictness-offset table in `audioQualitySettings.mjs` (the module now exposes a single hardcoded preset); the `low_latency` gate-disable / batch-skip branches and `audioQualityMode` / `voiceGateStrictness` / `realtimeEndpointingMode` reads in `audioManager.js`; and the `settingsPage.transcription.audioQuality` translation subtree across all 10 locale files (en / de / es / fr / it / ja / pt / ru / zh-CN / zh-TW). `initializeSettings()` performs a one-shot `localStorage.removeItem` of the three legacy keys on next launch. Behavior changes for users on non-default settings: anyone who had picked "Low latency" gets the speech-activity gate re-enabled (false captures may drop, perceived latency rises slightly); "Relaxed" strictness reverts to Standard; "Fast" realtime endpointing reverts to Balanced (500 ms endpointing for Deepgram, 1200 ms silence-duration for Bailian). Bailian streaming users see no behavior change because the local gate was already bypassed for their provider.
- **Linux platform support is no longer available.** Mouthpiece now only ships for macOS and Windows. The Linux-specific paste backends (`linux-fast-paste`, the ydotool installer/service, the GNOME Wayland D-Bus shortcut bridge), the Linux clipboard/hotkey/window-manager code paths, the AppImage / deb / rpm / tar.gz / Flatpak build targets, the Linux GitHub Actions jobs, the Linux-related `pasteToolsInfo` UI and translation keys, and the `dbus-next` runtime dependency have all been deleted. Existing Linux installations will keep working with their previously installed binary but will not receive future releases.

### Changed

- **Two audio defaults brought into ASR industry consensus during the panel removal.** While baking the formerly user-facing audio-quality knobs into a single hardcoded preset (see the matching Removed entry above), two values that earlier shipped as factory defaults were retuned against current dictation / streaming-ASR best practices: (1) `noiseSuppression` is now `false` (was `true`) — Deepgram's streaming-transcription Decision Matrix explicitly recommends disabling browser-side noise suppression for speech-to-text, and community evidence from Whisper desktop projects (e.g. roaldnefs/python-darwin#1) shows it strips speech-band detail and shortens word onsets / offsets, hurting accuracy especially for soft / accented speakers; `echoCancellation` and `autoGainControl` are unchanged. (2) The local VAD's `minSpeechRms` relaxes from `0.022` (≈−33 dBFS) to `0.014` (≈−37 dBFS) to align with the practical voice floor of −38 dBFS reported by Minuta and GPT-SoVITS, so soft / distant voices are no longer rejected at the gate. The other 11 audio settings audited in the same cross-validation pass — `autoGainControl`, `echoCancellation`, `openSnrDb` (10 dB), `closeSnrDb` (6 dB), `minSpeechMs` (220 ms; matches silero-vad's 250 ms default), `hangoverMs` (320 ms), `preRollMs` (300 ms; in the NeMo / faster-whisper 200–400 ms band), `minSpeechFrames` (4), `minVoicedRatio` (0.08), Deepgram `endpointing` (500 ms) / `utteranceEndMs` (1000 ms; matches Deepgram's documented floor), and Bailian `silenceDurationMs` (1200 ms; matches Aliyun's "long-sentence" example for dictation with mid-sentence pauses) — were judged in-range against silero-vad / WebRTC VAD / Deepgram / Aliyun docs and remain unchanged.
- **System settings page collapses developer surfaces behind an "Advanced" disclosure.** Previously the System page mixed user-facing items (current version, manual update check, reset app data) with developer surfaces (Debug mode toggle, "what gets logged" disclosure, model cache management) in one flat scroll, so 99% of users were staring at half a page of stuff they would never touch. The page now shows three blocks: top — `当前版本 + 检查更新` panel; middle — `重置应用数据` (always visible because it's an emergency escape hatch); bottom — a new collapsible `Advanced / 高级选项` disclosure that, when expanded, reveals the previously-always-visible `<DeveloperSection />` (Debug Mode + What gets logged) plus the Model Cache (open / clear) panel. Default-collapsed; chevron rotates 180° on expand. New CSS class set (`.settings-advanced-disclosure` + `.settings-advanced-toggle` + `.settings-advanced-hint`) gives it a dashed top divider and primary-tinted text when expanded so it reads as a discrete affordance, not just a button. New i18n keys `settingsPage.system.advanced.{title, description}` added to all 10 locales (en / zh-CN / zh-TW / de / es / fr / it / ja / pt / ru). No IPC, hook, store, or main-process change.
- **Dictation capsule now wears the Mouthpiece mouse logo, and its right-side audio bars actually react to your voice.** The recording-state capsule's left-side glyph used to be a generic blue/purple gradient avatar with two white "eye" dots — it was placeholder art that read as "some assistant", not "Mouthpiece". The same `h-8 w-8` rounded white card chrome now hosts an `<img>` of the renamed `src/assets/mouthpiece-icon.png` (the cartoon mouse holding a microphone, 1024×1024 source) via `object-cover`, so the brand identity finally lands the moment you start dictating. The right-side three-bar `BrandGlyph` was also a static prop — heights hardcoded to `[0.65, 1, 0.72]` regardless of input — which left two pseudo-meters in the capsule (the static right bars and the live bottom waveform dots) and made it ambiguous which was tracking the mic. `BrandGlyph` now takes `level` (the existing `audioLevel` prop, already wired through to the bottom waveform) and `isActive` (recording flag) and computes per-bar heights as `min(1, baseline[i] + level × gain[i])` with baselines `[0.42, 0.58, 0.45]` and gains `[0.95, 1.45, 0.78]` — middle bar lifts hardest, outers lift softer, with a 110 ms cubic-bezier ease so the bars settle smoothly between samples. When `isActive` is false (the capsule's idle/transcribing layer), all three bars hold at a calm 50% baseline so the glyph stops reading as fake-animated when there's no input. Both call sites (the `liveShellActive` recording layer and the `recordingLayerVisible` idle layer) pass the same props. The icon asset was renamed from the space-containing `Mouthpiece icon.png` to kebab-case `mouthpiece-icon.png` for cleaner imports.
- **Update prompt no longer auto-pops a confirmation dialog — the sidebar pill is now the only entry point (Phase 3 of the modal-style unification).** Previously, when `electron-updater` finished its silent download and the renderer received `update-status-changed` with `status: "downloaded"`, a `useEffect` in `ControlPanel.tsx` would auto-trigger the install confirm dialog and a `promptedDownloadedUpdateRef` deduped it per version. The auto-popup felt heavy because users got a centered modal interrupting their flow without having asked. The auto-popup `useEffect` and the dedup ref are removed; `useRef` import drops with them. The sidebar footer's existing "Install update" pill (`<ControlPanelSidebar updateAction={updateAction}>`) — already wired to `handleInstallUpdate` — is now the sole entry: it appears when `updateStatus.status` is `downloaded` or `installing`, and clicking it still opens the same `ConfirmDialog` (now wearing the Phase 1/2 Liquid Glass shell). The "ready to install" confirmation step is preserved per the user's preference; only the unsolicited entry point is gone. `handleManualCheckForUpdates` (the manual check from the System settings page) is also simplified — when its check returns `downloaded`, it now unconditionally calls `handleInstallUpdate` instead of guarding on the dedup ref, so the manual flow is independent of any auto-popup state. No IPC, store, hook, locale-key, or main-process change.
- **Bypass surfaces (referral modal, dropdown menus, tooltips, alerts, toasts) all routed through the unified Liquid Glass tokens (Phase 2 of the modal-style unification).** Six surfaces had been bypassing the central premium tokens and rolling their own classnames, leaving them visually inconsistent with the rest of the redesign. Each is now routed onto shared glass classes: (1) `ReferralModal.tsx` — overlay swaps `bg-black/60 backdrop-blur-lg` for `dialog-premium-overlay`, content drops `bg-card border-border shadow-[…]` for `dialog-premium-shell`. (2) `ui/dropdown-menu.tsx` — `DropdownMenuContent` and `DropdownMenuSubContent` lose the shadcn `bg-popover` + `border-border` + `shadow-lg` cluster and pick up a new `popover-glass-surface` class (translucent panel-bg + `backdrop-filter: blur(28px) saturate(160%)` + 4-layer elevation). (3) `ui/tooltip.tsx` — same `popover-glass-surface` treatment, and the little `border-t-popover` arrow under the tooltip is removed since the glass surface reads cleanly without it. (4) `ui/alert.tsx` — success/warning variants drop their hard-coded gradient strings (`bg-[linear-gradient(180deg,rgba(243,253,247,0.96)…)]` etc.) in favor of the new `.alert-premium-success` / `.alert-premium-warning` classes from Phase 1; destructive drops its hard-coded text colors and inherits from `.alert-premium-destructive`; rounded corners go from 18 px to 14 px to align with the rest of the cards. (5) `ui/Toast.tsx` default variant — `.toast-surface` repainted from the legacy dark HUD (`oklch(0.15 0.006 260)` near-black) to a glass surface; Toast.tsx text and close-button classNames switch from `text-white/*` to theme-aware `text-foreground` / `text-muted-foreground` so light mode reads correctly; `variantConfig` accent/progress strips drop the gradient `rgba(251,146,60…→…rgba(244,114,182…)` and use plain `bg-primary/55` (default) / `bg-destructive/70` (destructive) / `bg-emerald-500/70` (success). (6) `ui/Toast.tsx` destructive variant — `.toast-error-surface` repainted from the warm parchment (`rgba(255,249,245,0.98)` cream + `rgba(198,105,79,…)` warm border + radial peach glow) to the same glass shell as default, but with a destructive-tinted border + shadow + red radial accent; the `error-code-panel` and `toast-error-detail` inner blocks lose their parchment surfaces too. `SidebarModal.tsx` is currently dead code (no consumers in `src/`) and was left untouched in this pass; if it ever gets wired up it should also adopt the unified tokens. No JSX behavior changes, no IPC, no i18n keys.
- **Dialog and inline-alert tokens repainted with the Liquid Glass palette (Phase 1 of the modal-style unification).** The premium dialog/alert classes in `index.css` (`.dialog-premium-overlay`, `.dialog-premium-shell`, `-destructive`, `.dialog-premium-close`, `.alert-premium`, `-destructive`) were still wearing the legacy parchment/peach skin (`rgba(120,91,72,…)` brown borders, `rgba(255,251,247,…)` cream backgrounds, peach destructive radial accents) — visibly out of step with the rest of the redesign. They now use the same token set as the panel and cards: `var(--mp-control-panel-bg)` / 82% white shell, `var(--mp-control-border)` borders, `var(--glass-highlight)` for inset top edges, `var(--mp-card-shadow)`-style 4-layer elevations, and `var(--glass-blur) saturate(var(--glass-saturate))` for backdrop-filter. The overlay drops from `rgba(15,17,26,0.52)` + warm radial glow to a softer cool `rgba(15,23,42,0.32)` (light) / `rgba(0,0,0,0.5)` (dark) so the orb atmosphere still bleeds through behind the dim. Destructive variants switch from peach/red-brown accents to `--color-destructive`-tinted borders and shadows, matching the rest of the destructive UI. Also added two new variants — `.alert-premium-success` and `.alert-premium-warning` — using `--color-success` / `--color-warning` tints, so `alert.tsx`'s success/warning paths in Phase 2 can stop hard-coding gradient strings. CSS-only — `ConfirmDialog`, `AlertDialog`, `ErrorBoundary`, and `alert.tsx` destructive automatically inherit the new look without JSX changes.
- **Removed the "Recommended" tag next to Groq in the Transcription cloud provider tabs.** `CLOUD_PROVIDER_TABS` in `TranscriptionModelPicker.tsx` no longer flags Groq as `recommended: true`, so the "推荐 / Recommended" pill rendered by `ProviderTabs` next to its name is gone. No other provider keeps a recommended flag, so the visual hierarchy across the seven cloud transcription providers (OpenAI / Deepgram / Groq / Mistral / Soniox / Bailian / Custom) is now flat.
- **Atmosphere and sidebar opacity tuned closer to the demo so orb colors come through more clearly.** The atmosphere had been dialed back from `0.78` to `0.42` orb opacity to fix earlier "rainbow over-saturation", but the resulting page read noticeably duller than `liquid-glass-preview.html` (which uses `0.85` orbs + `0.55` sidebar). Returning halfway: `--glass-orb-opacity` goes `0.42 → 0.60` (light) / `0.32 → 0.45` (dark), and `--mp-control-sidebar-bg` drops `0.62 → 0.50` (light) / `0.50 → 0.42` (dark) so the sidebar lets more of the orb wash refract through. The onboarding override (which was `0.55`, intentionally more vivid than the previous control-panel value) keeps that emphasis by going `0.55 → 0.70`. CSS tokens only — no JSX or component change.
- **History date separators are now sticky glass pills with a per-day timeline rail.** The previous full-width sticky bar (a 11 px uppercase muted-foreground label inside `.history-date-header`) read as just another row in the list — it had no contrast against `.transcription-list-item` and "今天" / "2026年4月30日" were typographically interchangeable. Each day group is now a `.history-day-group` containing (a) a `.history-date-pill` — a tinted glass pill (linear-gradient `rgba(56,116,240, 0.14 → 0.06)` light, `rgba(122,166,255, 0.18 → 0.08)` dark) with a 1 px primary border, inset specular highlight, and `backdrop-filter: blur(20px) saturate(180%)` — that holds a 6 px primary dot, a primary-colored 12 px / 700 weight `primary` label, and a muted 11.5 px `secondary` label. The pill is `position: sticky; top: 8px; z-index: 12;` so when the user scrolls through a day's items the date stays anchored, then gets pushed away by the next group's pill. (b) A `.history-day-items` block holding the actual `<TranscriptionItem>` rows, with a `::before` 2 px rail running down its left edge — `linear-gradient(180deg, primary 50% → 18% 75% → transparent)` — that visually clusters the day's items as a timeline. `formatDateGroup` (string-only) is replaced with `formatDateGroupParts(date, t, locale) → { key, primary, secondary? }`: today / yesterday surface "今天 / 昨天" as primary and "2026年5月16日 · 周六" as secondary; days within the last week surface the localized weekday ("周三") as primary and full date as secondary; older entries surface full date as primary and weekday as secondary. The `key` (`YYYY-M-D`) is now used for grouping identity instead of the rendered label, so language switches and same-label-different-day edge cases don't collide. No IPC, store, hook, or new translation key — `Intl.DateTimeFormat` already covers all 10 locales.
- **Intelligence page hides Prompt Studio when text cleanup is disabled.** The Prompt Studio block (查看 / 自定义 / 测试 tabs that ride on `<PromptStudio />` plus its section header) on the Intelligence settings page is now gated on the `useReasoningModel` toggle. When "启用文本整理 / Enable Text Cleanup" is OFF the entire prompt-studio area collapses, since the prompt is only consumed by the reasoning pipeline that the toggle gates — exposing it while cleanup is off was confusing and let users edit a prompt that wouldn't run. Toggling the switch back on instantly restores the section. Pure render-time conditional in `SettingsPage.tsx`'s `intelligence` case; no IPC, store, hook, validation, or i18n change.
- **Segmented selectors and form inputs gain three subtle visual cues.** (1) Selected tab pill — both the Cloud / Local mode toggle in TranscriptionModelPicker and the provider tabs in ProviderTabs (transcription, intelligence) — now renders as a primary-tinted glass pill (`linear-gradient` of `rgba(56, 116, 240, 0.13 → 0.07)` light, `rgba(122, 166, 255, 0.18 → 0.10)` dark) with an inset top highlight, replacing the previously flat `bg-card` white slab. The selected button text also picks up `var(--color-primary)` for visual coherence. (2) Inactive provider/mode logos are dimmed to `opacity: 0.55 + grayscale(0.25)` so the active brand naturally pops; selected returns to full color. (3) Filled inputs (any `<input>` or `<textarea>` matching `:not(:placeholder-shown):not(:focus)`) get a 2 px primary inset strip on their left edge so a configured field reads as configured at a glance — implemented as inset box-shadow so layout never shifts. ApiKeyInput.tsx adds a small `Saved` / `已保存` badge in the label row (`.api-key-saved-badge`) when the key value is non-empty, with new `apiKeyInput.savedBadge` translations in all 10 locales (en / zh-CN / zh-TW / de / es / fr / it / ja / pt / ru). The two indicator divs (ProviderTabs sliding pill + TranscriptionModelPicker mode-toggle pill) gain a `data-tab-indicator` attribute and the buttons gain `aria-selected` to drive the new CSS without chasing fragile Tailwind utility classes.
- **Sidebar matches the demo, and every settings page now opens with a real page header.** Sidebar polish: the `--mp-control-selected-bg` token in light mode flips from solid `#e8f1ff` to translucent `rgba(56, 116, 240, 0.14)` and `--mp-control-selected-text` is `#1e54d4` to align with `--color-primary`, so the active pill refracts the glass behind it the way the demo did instead of reading as a solid blue slab. Nav rail tightens up: `padding: 14px 10px 8px` → `6px 10px 8px`, `gap: 2px` → `1px`, item `min-height: 34px` → `32px`, plus explicit `font-size: 12.5px / 500 / -0.005em` so items hit the demo cadence. Hover swaps to `rgba(125, 135, 160, 0.1)` (matches the demo) and active hover uses `color-mix(... var(--color-foreground) 4%)` so it darkens consistently in both modes. The footer becomes a flex column with `gap: 1px` so the sparse-footer state (only Support visible) doesn't read as half-empty. New `.settings-page-header` CSS class (h2 20 px / 700 / -0.02em + 13 px muted description, 14 px bottom padding plus a hairline) and a local `PageHeader` function in `SettingsPage.tsx`. `<PageHeader>` now sits at the top of every settings case — `general`, `hotkeys`, `transcription`, `intelligence`, `privacyData`, `system` — pulling `settingsModal.sections.X.label` and `settingsModal.sections.X.description` (the same i18n keys the sidebar already uses), so each page reads "Preferences / Appearance, sounds & startup" rather than dropping the user straight into a second-level "Appearance" SectionHeader. The transcription case had to wrap its delegated `<TranscriptionSection />` in a `space-y-6` container; intelligence and privacyData also gained the page header above their existing content. No IPC, store, hook, validation, or new i18n key — just visual structure. The plain `<p>{readableHotkey}</p>` line in `renderActivationStep` is now wrapped in `.activation-hero` — a centered block containing a `.activation-halo` (radial primary→purple gradient blurred 24 px, breathing 2.6 s loop with `activation-breathe` keyframe at 0.45→0.85 opacity / 0.96→1.06 scale) and a `.activation-keycap` (18 px / 600 weight, 14 px radius, layered glass: inset top + bottom highlights, 0.5 px hairline, 1 px close, 12 px diffuse, dark-mode equivalent included). When a `PermissionCard` flips into `permission-card-granted`, the inner check svg now plays the existing `check-pop` keyframe (0.55 s cubic-bezier overshoot) — the icon was already in place, this just ties it to a celebration animation. Both new animations inherit the global `prefers-reduced-motion` rule's `0.01ms` override, so accessibility is preserved. JSX touch is a single `<p>` swap; no IPC, no i18n, no new state. Phase OB-4 of the onboarding redesign.
- **Onboarding step rail gets per-step identity colors and a more spacious cadence.** `.wizard-step-pill` height grows from 34 px to 44 px, gap 4 → 6, font 12 → 13. `.wizard-step-icon` grows from 20 × 20 px (round) to 32 × 32 px (9 px squircle) with the inner svg bumped to 16 px. Each step's icon now carries its own gradient identity: permissions/Shield is blue→purple `#5b8df8 → #7b6cff` ("security"), hotkeySetup/Command is orange→amber `#ffa15e → #ff7245` ("action"), activation/Mic is green→teal `#4dd49e → #2db872` ("voice ready") — selectors target `:nth-child(1)`, `(3)`, `(5)` because connector divs are interleaved between pills. Active state amplifies the per-step shadow with a 3 px glow ring in the matching tint plus a `scale(1.04)` lift; completed state ringed in a muted success-green and the connector below uses a vertical success-tint gradient. CSS-only — no StepProgress JSX, OnboardingFlow logic, step copy, or i18n key was touched. Phase OB-3 of the onboarding redesign.
- **Onboarding auth step is now a hero glass card.** `.wizard-auth-panel` widens from 380 px to 480 px, radius lifts from 14 px to 18 px, padding becomes `36 32 28`, and a soft purple radial glow leaks from the upper-right corner to give the first-run moment a clear "this matters" beat. The Mouthpiece logo grows from 44 px to 64 px with a 16 px radius, an inset top highlight and a 12 px blue drop shadow that lifts it off the glass. The first `<p>` inside `.auth-setup-header` and `.email-verification-header` (the step title — covers all 6 branches across AuthenticationStep + EmailVerificationStep) now renders as a 22 px / 700 weight gradient sweep from `#3974ff` to `#a87dff` (atmosphere blue → purple), with the dark-mode pair lightened to `#6fa8ff` → `#c2a4ff`. CSS-only — no AuthenticationStep or EmailVerificationStep JSX, copy, validation, or i18n key was touched. Phase OB-2 of the onboarding redesign.
- **Onboarding wizard now sits on the same Liquid Glass atmosphere as the Control Panel.** The 4-orb atmosphere layer is mounted as the first child of `.onboarding-shell` and runs at `--glass-orb-opacity: 0.55` (vs the Control Panel's `0.42`) — onboarding is a once-per-install moment, so the atmosphere leans more vivid for first-impression weight. `.onboarding-shell` gained `position: relative` + `isolation: isolate` so the atmosphere can absolute-position behind everything via document order. `.wizard-rail-panel`, `.wizard-panel` and `.wizard-auth-panel` all now consume `var(--mp-card-shadow)` plus `backdrop-filter: blur(36px) saturate(135%)` and a 1 px specular `::before` highlight, with `border-radius` lifted from 8 px to 14 px so they match the Control Panel cards. `.wizard-footer` now blurs the panel bg at 28 px / saturate 160% with a 70% panel-bg color-mix, so it reads as a frosted action bar instead of a flat slab. CSS-only plus a single 6-line atmosphere injection in `OnboardingFlow.tsx` — no step content, validation, copy, IPC, or routing changed. Phase OB-1 of the onboarding Liquid Glass redesign.
- **Liquid Glass polish — atmosphere is now subtle, every card shares one elevation, and a couple of stragglers were brought into the system.** This pass tunes the demo→production gap reported on screenshots: (a) `.control-panel-titlebar` is now fully transparent so the seam between sidebar and main vanishes, (b) atmosphere orbs are halved in size (`60vw` → `min(36vw, 540px)` etc.) and dropped from `0.78` → `0.42` opacity light / `0.6` → `0.32` dark, with their internal `saturate(160%)` brought back to `100%` so they read as soft halos instead of dominant blobs, (c) glass surfaces saturate is `180%` → `135%` so refracted colors no longer get double-amplified, (d) the sidebar diagonal gloss loses `mix-blend-mode: overlay` (which was amplifying hue contrast) and drops to `0.18` opacity, (e) all card surfaces (`.history-panel`, `.history-empty`, `.settings-group`, `.dictionary-loose-card`, `.permission-card`, `.control-panel-banner`) now share a single `--mp-card-shadow` token — a 4-layer stack (inset top specular + 0.5 px hairline + 1 px close lift + 18 px diffuse drop) with separate dark-mode values that use `rgba(0,0,0,…)` instead of the previous `rgba(13,18,30,…)` so the elevation is actually visible against charcoal. Border-radius is unified to `14 px` across primary cards. The Phase-4 `[class*="bg-card"]` / `[class*="bg-surface-2"]` scope override now also applies `box-shadow`, `border-color`, and `border-radius`, so SettingsGroup, DeveloperSection, PromptStudio, TerminologySettingsCard etc. are visually identical to my CSS-defined cards. DictionaryView's populated-state header / input / chips / hint cluster is wrapped in a new `.dictionary-loose-card` glass surface (replacing the original "loose chips floating on bg" layout that read fine on a flat bg but not on the atmospheric one). ReasoningModelSelector's cloud-mode wrapper at line 839 — a `border border-border rounded-lg` with no background — gets a `bg-card/40` so the global override picks it up and it stops reading as a flat white slab on the Intelligence page. Phase 5 of the Liquid Glass restyle.
- **Permission cards, ModelCardList tiles and ProviderTabs containers now match the Liquid Glass system.** `.permission-card` gained a 12 px radius, a 1 px specular top edge, an inset highlight and the same `backdrop-filter` as panels. Inside `.control-panel-shell`, the Tailwind utilities `.bg-surface-1`, `.bg-surface-raised` and `dark:bg-surface-1` are now scope-overridden to translucent glass values plus a soft inset border, with separate light/dark variants — this propagates the glass treatment to ModelCardList default tiles and the ProviderTabs container without touching their JSX or the global Tailwind tokens (so dialogs, shadcn cards and the onboarding wizard remain untouched). Phase 4 of the Liquid Glass restyle.
- **Form inputs, the active sidebar item and history rows pick up the Liquid Glass material.** All `.control-panel-shell` inputs, textareas and select triggers now carry `backdrop-filter: blur(20px) saturate(160%)` plus an inset top highlight, with the focus glow becoming a layered `inset highlight + 3 px primary ring` and `[data-state="open"]` select triggers using the same focus state. The active sidebar item gained a 3-layer shadow (0.5 px tint border + inset highlight + soft primary glow), making it pop against the now-translucent sidebar. Transcription list rows gained an explicit `hover` background tinted via `color-mix(... var(--color-foreground) 4%)` so hover stays visible on the new transparent main area. CSS-only — no component, IPC, or i18n change. Phase 3 of the Liquid Glass restyle.
- **Control Panel sidebar and panels now refract the atmosphere as Liquid Glass.** The sidebar bumps from `blur(18px) saturate(140%)` to `blur(36px) saturate(180%)` and gains a 1 px specular top-edge highlight plus a soft diagonal gloss. The history panel, settings groups, settings inline cards, banner and date headers now all use `backdrop-filter` with the same blur/saturate, with semi-transparent fills so the atmosphere's color shows through. Card corner radius was lifted from 8 px to 14 px (12 px for banners, 10 px for inline cards) and a soft layered shadow replaces the previous flat `0 1px 2px`. No view, sidebar order, copy, or component structure changed — this is Phase 2 of the Liquid Glass restyle.
- **Control Panel now sits on a Liquid Glass atmosphere layer.** The window background gained four slowly-drifting pastel orbs (peach / lavender / blue / mint in light mode, deep purple / teal / wine in dark mode) sitting behind the sidebar and main content. The main scroll area is now transparent so cards float over the atmosphere instead of a flat slab. New `--glass-*` design tokens were added for use by subsequent Liquid Glass passes. The atmosphere respects `prefers-reduced-motion` and uses `pointer-events: none` so it can never block interactions. This is Phase 1 of a larger Liquid Glass restyle that preserves all existing UI structure, naming, and ordering.

### Fixed

- **Linux uninstaller and clipboard helper now match the current `mouthpiece` cache namespace.** `resources/linux/after-remove.sh` previously only cleaned `~/.cache/openwhispr/`, leaving the live `~/.cache/mouthpiece/` model directory behind on uninstall; it now removes both. `resources/linux-fast-paste.c` no longer claims an `openwhispr` D-Bus session token or registers its uinput device as `openwhispr-paste` — both identifiers are now `mouthpiece`, matching the rest of the runtime (the `gnomeShortcut` D-Bus service is `com.mouthpiece.App`).
- **History panel keeps its rounded top corners while scrolling, and the date scrim now matches the panel's atmospheric tint.** Two issues from the prior pass: (a) once the user started scrolling, the panel's rounded top corners disappeared because the panel itself was scrolling along with the outer `.control-panel-content-scroll` — the corners scrolled out of the visible viewport, leaving a flat top edge; (b) the sticky scrim was hard `rgba(255,255,255,0.96)` pure white, which read as a stark white strip against the panel's atmospheric pink/lavender wash. Fix is structural: the History view now scrolls **internally**. `.history-view` is a flex column with `height: 100%`; the `.w-full` wrapper gets `flex: 1; min-height: 0;`; `.history-panel` / `.history-empty` go back from `overflow: clip` to `overflow: hidden` and pick up `flex: 1; display: flex; flex-direction: column; justify-content: center;`; a new `.history-scroll-area` (flex: 1, overflow-y: auto, overscroll-behavior: contain) wraps the day groups and is the actual scroller. Result: the panel chrome (border, glass background, rounded corners, shadow) stays anchored in the viewport at all scroll positions, and the sticky date row resolves against the inner scroll container — so it never escapes the rounded clip. The scrim background also shifts from pure white to `rgba(250, 247, 251, 0.95)` (light) / `rgba(31, 33, 41, 0.95)` (dark) — a faint lavender/cool tint at 95% opacity, so the 5% bleed-through inherits whatever atmosphere is behind the panel and the scrim reads as a continuation of the panel rather than a separate white slab. Loading and empty states center vertically inside the new flex panel via `justify-content: center` (no JSX changes needed; their single inner div is the only flex child).
- **History date pill is now a true scrollbar barrier — rows can't poke around it.** The previous implementation made the bubble itself sticky, so transcription rows scrolled up and "passed alongside" the bubble's right edge (the pill is fit-content, not full-width), leaving wrapped Chinese text visible to the right of the pill on the same vertical line. The pill is now wrapped in a full-width `.history-date-row` element that holds the sticky behavior — `position: sticky; top: 0; padding: 12px 16px 10px;` with an opaque `rgba(255,255,255,0.96)` (light) / `rgba(28,32,44,0.96)` (dark) background. The visible bubble (`.history-date-pill`) sits inside the scrim as a normal inline-flex element, retaining its tinted glass surface but losing its own sticky / heavy shadow (the scrim now handles obscuring). Item padding moves from the day-group onto `.history-day-items` (`padding: 0 16px 0 32px`), the rail offset shifts from `left: 0` to `left: 16px`, and last-group bottom padding moves to `.history-day-group:last-child .history-day-items` so the bottom-most row keeps its breathing room.
- **History date pill no longer bleeds the row beneath it through its background.** The previous pill background was a single `linear-gradient(rgba(56,116,240, 0.14 → 0.06))` plus `backdrop-filter: blur`, which works on a static page but leaves the pill ~85% transparent — so as a `<TranscriptionItem>` row scrolled underneath the sticky pill, the row's text (e.g. "11:36 这个，你检查一下") visibly overlapped the pill's own label, making the pill look broken. The pill now layers the blue tint on top of an opaque card base (`rgba(255,255,255,0.94)` light, `rgba(28,32,44,0.94)` dark), boosts the gradient to `0.18 → 0.08` (light) / `0.22 → 0.10` (dark) so the tint stays visible after the opaque layer joins, strengthens the border to 28% / 32% primary, and adds a softer 12 px diffuse drop shadow + 2 px close shadow so it reads as elevated above the scrolling content. Backdrop-filter is kept for fallback aesthetics but is no longer load-bearing.
- **History date pill now actually sticks to the top while scrolling.** `.history-panel` was using `overflow: hidden`, which per CSS spec turns it into a "scroll container" — and since the panel itself doesn't scroll (the real scroller is `.control-panel-content-scroll` higher up in the tree), the sticky pill was scoped to a non-scrolling ancestor and never engaged. Switched the panel and `.history-empty` to `overflow: clip`, which still clips overflow against the 14 px rounded corners but does NOT create a scroll container — so `position: sticky; top: 8px;` now resolves against the actual `.control-panel-content-scroll` and the pill anchors to the panel's top edge as the user scrolls through a day's items.
- **`settingsModal.updates.*` translation keys no longer render as raw strings on the System page.** All 17 call sites in `SettingsPage.tsx` and `ControlPanel.tsx` were calling `t("settingsModal.updates.…")`, but the actual translations had been moved to `settingsPage.general.updates.*`, so the System page (and the manual "check for updates" path in the Cmd+Shift+P → System block) showed raw key strings like `settingsModal.updates.title` / `settingsModal.updates.devMode` / `settingsModal.updates.checkForUpdates` rendered into the UI. Every reference is swapped to `settingsPage.general.updates.*` in one mechanical pass; nothing else changes.
- **Renderer build no longer fails on `buildCustomDictionaryPrompt`.** The custom-dictionary helper was authored as CommonJS (`module.exports`) but imported by the Vite-bundled `audioManager`, which Rollup's static analyzer rejected with `"buildCustomDictionaryPrompt" is not exported`. The helper is now an ES module (`customDictionaryPrompt.mjs` with `export`), the `audioManager` import points at the new extension, and the unit test loads it via dynamic `import()` to match.

### Internal

- **Dropped stale OpenWhispr / VoiceInk references across docs, scripts and CI.** `CLAUDE.md`, `AGENTS.md`, `DEBUG.md`, `LOCAL_WHISPER_SETUP.md`, `TROUBLESHOOTING.md` and `WINDOWS_TROUBLESHOOTING.md` now describe the project as Mouthpiece, point at the `~/.cache/mouthpiece/` cache and the `MOUTHPIECE_LOG_LEVEL` env var, and only mention the legacy paths / variables in their explicit "upgrading from older builds" notes. `scripts/lib/download-utils.js` ships a `Mouthpiece-Downloader` User-Agent and `scripts/check-download-utils-fallback.js` mocks the real `NotWizard/Mouthpiece` repo. The C source header for `resources/windows-fast-paste.c` is updated to match. The `release.yml` and `build-and-notarize.yml` workflows now export `VITE_MOUTHPIECE_API_URL` / `VITE_MOUTHPIECE_OAUTH_CALLBACK_URL` (preferred by `runtimeConfig.ts`) and read from either the new `vars.VITE_MOUTHPIECE_*` or the legacy `vars.VITE_OPENWHISPR_*` repository variables, so CI keeps building whether or not the GitHub repo variables have been renamed yet.

## [1.3.1] - 2026-05-17

### Fixed

- **Globe / right-side modifier hotkey now self-heals after a TCC reset.** When macOS revokes Accessibility (e.g. on the v1.2 → v1.3 self-signing migration), the Swift `macos-globe-listener` exits with `Failed to create event tap` and stays dead. The app now retries the spawn whenever the user brings a window back to focus or activates the app from the dock, so once Accessibility is re-granted the `RightCommand` / `Globe` hotkey resumes without the user needing to manually toggle the hotkey in Settings.
- **Windows Push-to-Talk listener no longer self-disables on hotkey change.** `windowsKeyManager.start()` would replace its child process while the previous child's async `exit` handler was still pending; when that handler eventually fired it called `reportError` against the new child and emitted `windows-ptt-unavailable`, which disabled the freshly-started listener. Each listener handler now identity-checks against its own child reference, and an `_isStopping` flag suppresses the spurious error path.
- **Windows Push-to-Talk listener self-heals on focus.** Mirroring the macOS Globe recovery: when the keyboard hook is detached (AV interception, sleep / wake, UAC), the listener now respawns the next time the user returns to the app instead of staying dead until the user re-selects the hotkey.
- **macOS fast-paste binary recovers within the session after Accessibility is re-granted.** Previously a single CGEvent failure permanently set `fastPasteChecked = true; fastPastePath = null`, forcing every subsequent paste through the slow AppleScript fallback for the rest of the run. The negative cache is now TTL-based (60 s by default) and is invalidated immediately when `isTrustedAccessibilityClient` flips back to true.
- **`update-hotkey` IPC now triggers native-listener restart on its own.** `HotkeyManager` extends `EventEmitter` and emits `hotkey-changed` after every successful update, so callers no longer need to remember to also call `notifyHotkeyChanged` for the macOS Globe / Windows native listener to refresh.
- **macOS hotkey capture mode no longer fires dictation while recording a new hotkey.** Entering the capture flow now stops `globeKeyManager` when the active hotkey is `GLOBE` or a right-side modifier, and exiting capture mode restarts the listener.
- **OpenAI empty response no longer silently masquerades as a successful cleanup.** `processWithOpenAI` previously logged `OPENAI_EMPTY_RESPONSE_FALLBACK` and returned the raw transcript, hiding the failure from upstream metrics and toasts. It now throws so the existing `audioManager` reasoning catch-and-fall-back-to-raw path runs and any future toast / telemetry can react.
- **Anthropic IPC handler stops crashing on empty `content` arrays.** Refusal / safety-stop responses can return `content: []`, which would throw `Cannot read properties of undefined (reading 'text')`. The handler now defensively extracts the first `type === "text"` block and returns `{ success: false, error }` with a refusal-aware message. The header was also corrected to canonical lowercase `x-api-key`.
- **`llama-server` lazily restarts when inference finds it dead.** Previously `inference()` threw `"llama-server is not running"` after an OOM / sleep / crash, requiring the user to toggle the model. The function now retries `start(modelPath, lastOptions)` once before failing, matching the lazy-restart behavior already present in `whisperServer` and `qwenAsrServer`.
- **GNOME Wayland accepts `RightX` modifiers and refuses modifier-only hotkeys.** `convertToGnomeFormat` previously silently dropped `RightControl`, `RightAlt`, etc. (registering a bare key like `K`) and turned modifier-only hotkeys like `RightCommand` into invalid keysyms. `Right` is now stripped before mapping so left/right modifiers produce the same GNOME binding, and modifier-only hotkeys return `""` so `hotkeyManager` falls back to X11 globalShortcut.
- **`userDataPathResolver` always picks the current Mouthpiece directory once it has real state.** Previously the score-based ranking could hand the user back to a fat legacy `OpenWhispr` directory and make recently-saved keys / DB writes appear to vanish. The current directory now wins as soon as it has a non-zero state score; only-legacy boots still pick legacy but now report `migratedFrom` / `migrationTarget` so callers can run a one-time copy.
- **`saveAllKeysToEnvFile` no longer drops user comments and unknown env vars.** The function now reads the existing `.env`, merges allow-listed keys via the new pure `mergeEnvFile` helper, and preserves comments / unknown keys verbatim. `QWEN_ASR_MODEL` was added to `PERSISTED_KEYS` so it stops being silently deleted on every save.
- **`reasoningProvider` switching to a cloud provider now persists to `.env`.** The previous logic only persisted `REASONING_PROVIDER` when the value was `"local"`, and actively cleared it for cloud providers — leaving any main-process code that read `process.env.REASONING_PROVIDER` directly with a stale value. Provider switching is now driven by a pure `computeReasoningEnvUpdate` helper that always persists non-empty values and clears `LOCAL_REASONING_MODEL` plus stops `llama-server` for any non-`local` choice (including empty / disabled reasoning).
- **Project-root `.env` no longer permanently shadows `userData/.env`.** The early-init `require("dotenv").config({ path: __dirname/.env })` at `main.js:5` ran before `EnvironmentManager`, and dotenv's no-override semantics meant any value the user typed in the UI could be silently reverted on next launch by a stale dev `.env`. The early call is gone, and `EnvironmentManager` no longer falls back to `__dirname/../../.env`.
- **OAuth deep links arriving before `windowManager` is built are now queued.** macOS delivers `open-url` before `app.whenReady()` during cold launch, and second-instance launches arrived in the first ~300 ms while `startApp` was still wiring `windowManager`. Both paths now wait on a new `startupReadyPromise` and replay queued `mouthpiece://` URLs once the control panel exists.
- **macOS `globeKeyManager` and Windows native listener wait for the real hotkey to load before starting.** `globeKeyManager.start()` used to fire while `currentHotkey` was still the platform default `GLOBE`, so a real `Fn` press during the first second of startup could falsely trigger dictation. The Windows listener startup similarly raced a hardcoded 3-second timer. Both now bind to `hotkeyManager.once("hotkey-ready", ...)`.
- **Hotkey load failure leaves the session with at least a default hotkey.** `loadSavedHotkeyOrDefault` previously only logged on exception, leaving the session unbound until restart. The catch arm now retries with `process.env.DICTATION_KEY` or the platform default and still emits `hotkey-ready`.
- **`will-quit` now waits for every server / streaming helper to release.** The handler `event.preventDefault()`s once, runs synchronous teardown for `hotkeyManager` / `globeKeyManager` / `windowsKeyManager` / `macOSPermissionFlowManager` / `updateManager`, then awaits a `Promise.allSettled` over `whisperManager.stopServer()`, `parakeetManager.stopServer()`, `qwenAsrManager.stopServer()`, the local `modelManager.stopServer()`, and the streaming helpers (`assemblyAiStreaming.cleanupAll`, `deepgramStreaming.cleanupAll`, `sonioxStreaming.disconnect`, `bailianRealtimeStreaming.disconnect`) before calling `app.exit(0)`. Hard quits no longer leave whisper / llama / parakeet child processes orphaned.
- **`authBridgeServer` stops hanging on quit during in-flight OAuth callbacks.** A new module-level `Set<Socket>` tracks every accepted connection; on `will-quit` the sockets are destroyed and `closeAllConnections()` is called before `close(callback)` resolves, so a long-lived keep-alive connection can no longer block app exit.
- **Custom dictionary prompt is bounded so the most recently added words survive Whisper's 224-token cap.** `getCustomDictionaryPrompt` now delegates to a new `buildCustomDictionaryPrompt` helper that walks the words newest-first, joins until a 600-character budget is exhausted, and returns the result in original order. Newly-added terms are no longer silently dropped, and runaway dictionaries no longer balloon cloud reasoning token costs.

### Internal

- `CLAUDE.md` now requires every commit that touches user-visible behavior, fixes a bug, or alters developer workflow to update `CHANGELOG.md` in the same commit (Keep a Changelog format under `[Unreleased]`).
- New pure helper modules with focused unit tests, all callable outside Electron: `src/helpers/envFile.js` (mergeEnvFile), `src/helpers/reasoningEnvUpdate.js` (computeReasoningEnvUpdate), `src/helpers/fastPasteCache.js` (createFastPasteCache), `src/helpers/customDictionaryPrompt.js` (buildCustomDictionaryPrompt).
- `HotkeyManager` now extends `EventEmitter`, emitting `hotkey-changed` after every successful `updateHotkey` and a one-shot `hotkey-ready` once `loadSavedHotkeyOrDefault` settles.
- `IPCHandlers` exposes a `getGlobeKeyManager` accessor so `set-hotkey-listening-mode` can manipulate the macOS Globe listener without circular imports.
- 58 new test cases across 9 files (`tests/env-file-merge.test.mjs`, `tests/reasoning-env-update.test.mjs`, `tests/dotenv-shadow-removal.test.mjs`, `tests/windows-key-listener-recovery.test.mjs`, `tests/clipboard-fast-paste-ttl.test.mjs`, `tests/hotkey-manager-events.test.mjs`, `tests/capture-mode-stops-globe.test.mjs`, `tests/reasoning-error-paths.test.mjs`, `tests/gnome-shortcut-format.test.mjs`, `tests/user-data-current-priority.test.mjs`, `tests/startup-ordering.test.mjs`, `tests/cleanup-and-dictionary-cap.test.mjs`).

## [1.3.0] - 2026-05-16

### ⚠️ One-time re-authorization required after this update

After updating to v1.3.0 you will be asked to re-grant **Accessibility** (and **Microphone**, if you use voice dictation) **one final time**. macOS treats the new build as a different app because the code-signing identity changed. Once you re-grant, every future Mouthpiece update will retain your permissions automatically.

### Changed

- **Stable code-signing identity for persistent macOS permissions**: macOS releases are now signed with a 10-year self-signed code-signing certificate (CN `Mouthpiece Code Signing`) instead of ad-hoc signing. The codesign Designated Requirement is now anchored to that certificate, so TCC (the system that tracks Accessibility / Microphone grants) recognizes every future update as the same app and preserves your permissions across releases. No Apple Developer ID is involved; this works without notarization. See `docs/release/code-signing-runbook.md` for the full mechanism.
- Homebrew cask now strips the Gatekeeper quarantine attribute on install via a `postflight` block, so first-launch from `brew install --cask` no longer needs the right-click → Open dance.

### Internal

- New `scripts/setup-self-signed-cert.sh` that generates the cert + .p12 (one-time, saved outside the repo at `~/.mouthpiece-signing/`).
- Release workflow validates the Designated Requirement on every macOS build and hard-fails if signing silently fell back to ad-hoc.
- New `MAC_SELFSIGN_CERT_BASE64`, `MAC_SELFSIGN_CERT_PASSWORD`, `MAC_SELFSIGN_IDENTITY` GitHub Actions secrets replace the previous Apple Developer ID gating.

## [1.2.0] - 2026-05-16

### Removed

- **Auto-Learn Correction Monitoring**: Removed the feature that monitored user edits in the target app after a paste and automatically appended corrected words to the custom dictionary. The required AppleScript `AXEnhancedUserInterface` flip caused 1-2 second freezes in Chromium-based target apps (Chrome, VS Code, Cursor, Slack, Discord, Notion, etc.) every time a paste finished, because each invocation forced the app to rebuild its accessibility tree on the main thread. Manual custom dictionary, glossary terms, blacklist, and homophone mappings remain available.
- Removed dependent surfaces along with the feature: the `Auto-learn corrections` toggle in Settings → Dictionary, the pending-suggestions review panel inside the terminology card, the dictionary-suggestion overlay toast, the `setAutoLearnEnabled` / `onCorrectionsLearned` / `undoLearnedCorrections` IPC bridges, the `block_auto_learn` sensitive-app policy action, and the `allowSensitiveAppAutoLearn` privacy switch.
- Removed the platform text-monitor binaries (`macos-text-monitor`, `linux-text-monitor`, `windows-text-monitor`), their compile / download scripts, and the matching GitHub Actions release workflows.

### Changed

- Renamed `src/helpers/textEditMonitor.js` to `src/helpers/targetAppCapture.js`, retaining only the foreground-app PID capture used by paste targeting at hotkey press.
- Existing words that had previously been auto-learned into the user dictionary are kept as ordinary custom dictionary entries; no migration is required.

## [1.1.2] - 2026-03-19

### Added

- Added Deepgram as a dedicated cloud transcription provider with a provider-level realtime streaming toggle
- Added Soniox as a dedicated cloud transcription provider with separate async and realtime transcription paths
- Added live partial transcript display in the dictation overlay while realtime transcription is active

### Changed

- Exposed Alibaba Bailian as a dedicated cloud transcription provider in Settings instead of routing DashScope through the generic custom provider
- Clarified the custom transcription provider as the generic OpenAI-compatible endpoint path and automatically migrate legacy `custom` + DashScope transcription settings on startup
- Tightened renderer network boundaries and consolidated API key persistence to reduce secret exposure across transcription providers
- Fixed CommonJS and ESM import compatibility in the main branch packaging path

### Fixed

- Fixed error toast close behavior and refreshed its visual styling
- Removed the signed-out sidebar hint and unified the model cache directory layout

## [1.1.1] - 2026-03-18

### Added

- Restored automatic app update checks on startup with a 12-hour background polling interval
- Added a control panel sidebar update action that appears after a new version finishes downloading in the background

### Changed

- Update installation now waits for explicit user confirmation before restarting the app
- Release publishing is now aligned with the current `NotWizard/Mouthpiece` repository so packaged builds and update metadata ship from the same source

## [1.0.0] - 2026-03-17

### Changed

- Reset the release numbering for this standalone repository so the first official Mouthpiece release starts at `1.0.0`
- Improved API key setup with direct input, blur-time masking, and an eye toggle for reveal/hide
- Added Alibaba Bailian as a dedicated reasoning provider
- Fixed mac packaging preflight so local builds can reuse bundled whisper binaries without failing on unnecessary release lookups

## [1.5.5] - 2026-03-01

### Added

- **Mode-Aware File Size Validation**: Upload UI now enforces file size limits per transcription mode — local is unlimited, BYOK and Cloud free are capped at 25 MB, Cloud pro at 500 MB — with contextual messaging and CTA buttons (Create Account, Upgrade, Switch to Cloud)
- **Large File Chunking**: Files over 25 MB are automatically split via FFmpeg and transcribed in parallel with per-chunk progress reporting
- **Gemma 3 Local Models**: Added Gemma 3 (1B, 4B, 12B, 27B) to the local model registry with provider icon
- **Groq Model Updates**: Added new Groq models and removed deprecated ones (Maverick, Kimi K2 Instruct)
- **Notes Editor Formatting Shortcuts**: Cmd+B (bold), Cmd+I (italic), Cmd+E (code) keyboard shortcuts in the notes editor
- **Linux Wayland Paste Improvements**: Added ydotool support and improved wl-copy reliability for Wayland paste
- **Granular Build Scripts**: Added individual build target scripts for more flexible CI/CD

### Fixed

- **Fn/Globe Hotkey**: Fn key now correctly treated as equivalent to Globe key on macOS
- **GPU Activation**: Fixed GPU activation flow and Vulkan fallback behavior
- **Groq i18n**: Updated Groq model descriptions and added missing translations across all locales

## [1.5.4] - 2026-02-25

### Added

- **Auto-Learn Correction Monitoring**: Detects user edits after paste and automatically updates the custom dictionary with learned corrections; native text monitor binaries for macOS (AXObserver with PID-based AX targeting), Windows, and Linux (with download-first strategy and CI workflow for prebuilt binaries); undo button on auto-learned dictionary toast; dictionary settings UI with translations across all locales
- **Config-Driven STT Routing**: STT mode (batch vs streaming) now driven by `/api/stt-config` per context (dictation vs notes); streaming provider adapter map supports Deepgram and AssemblyAI, replacing hardcoded Deepgram IPC calls with a generic interface
- **Live Toggle in Notes**: "Live" toggle in NoteEditor lets users override between streaming and batch transcription for notes

### Fixed

- **STT Metadata Forwarding**: Forward complete STT metadata (`sttWordCount`, `sttLanguage`, actual Deepgram model, audio bytes, `stt_processing_ms`) and client end-to-end latency (`client_total_ms`) to API logging
- **BYOK Transcription Logging**: Fixed BYOK reasoning incorrectly suppressing transcribe logs

## [1.5.3] - 2026-02-24

### Added

- **Unified GPU Banners**: Replaced dual CUDA/Vulkan banners on the home screen with a single GPU acceleration banner; added GPU banners to Transcription Settings and AI Text Enhancement Settings
- **GpuStatusBadge Redesign**: Auto-retry flow (download → activating → GPU active) with 15s timeout, replacing confusing "CPU Only" and "Re-detect GPU" states; swapped hardcoded hex colors for `bg-success`/`bg-warning` design tokens
- **Streaming Usage Tracking**: Wired up the previously-uncalled `/api/streaming-usage` endpoint so Deepgram streaming transcriptions report word counts to the server
- **Cloud API Telemetry**: Forward STT metadata (`sttProvider`, `sttModel`, processing time, audio duration/size/format) and `clientVersion`/`clientType`/`appVersion` to all cloud API requests
- **Internationalization**: Added 15 missing i18n keys (`app.mic.*`, `app.commandMenu.*`, `app.toasts.*`, `app.oauth.*`, `notes.enhance.title`) across all 10 locale files

### Fixed

- **Windows Blank Screen**: Fixed blank screen on return from sleep/minimize by adding `render-process-gone` handler, `isCrashed()` health checks on show/tray/second-instance paths, `backgroundColor` and `backgroundThrottling` to window config, and `disable-gpu-compositing` for win32
- **IPC Echo Loop**: Broke infinite IPC bounce in floating icon auto-hide toggle by guarding the setter with an early return when the value hasn't changed
- **GPU Banner Navigation**: GPU banner "Enable GPU" button now navigates to the correct `"intelligence"` settings section instead of invalid `"reasoning"` ID
- **AI CTA Deep Link**: Replaced legacy `"aiModels"` alias with canonical `"intelligence"` section ID in the AI enhancement CTA button
- **Custom Endpoint Routing** (#311): Moved `reasoningProvider === "custom"` check to the top of `getModelProvider()` so custom endpoint models are never misrouted through built-in providers; custom models now show a neutral Globe icon
- **KDE Wayland Terminal Detection**: Detect Konsole via `kdotool` (fast path) or KWin `supportInformation` via `qdbus` (zero-install fallback) so terminals receive `Ctrl+Shift+V` instead of `Ctrl+V`
- **RAM Leak on Provider Switch**: Whisper, Parakeet, and llama-server processes now stop when switching to cloud providers, freeing loaded models from RAM
- **Streaming Usage Session Refresh**: Wrapped `cloudStreamingUsage` in `withSessionRefresh` so expired sessions auto-refresh instead of silently dropping word counts
- **Duplicate Transcription Logs**: Skip telemetry logging in streaming-usage and transcribe endpoints when reasoning is enabled (the `/api/reason` endpoint already creates the combined row)
- **Usage Cache Invalidation**: `useUsage` hook now listens for `usage-changed` events to invalidate its cache and refetch immediately after transcription
- **macOS Binary Architecture**: Added Mach-O header verification to globe-listener and fast-paste build scripts; force rebuild when architecture-specific hash file is missing; runtime architecture check before spawning binary
- **Globe Key Listener Resilience**: Auto-restart globe key listener on unexpected exit code 0 (sleep/wake invalidation); reset restart counter after sustained uptime; only treat "Failed to create event tap" as fatal
- **Parakeet Long Recordings**: Lowered max segment duration from 30s to 15s for more reliable chunked transcription; downgraded reasoning failure log from error to warn

## [1.5.2] - 2026-02-24

### Fixed

- **Reasoning Output**: Resolved empty output for Qwen3/GPT-OSS models by raising local inference minimum tokens from 100 to 512; fixed custom endpoint models misrouting by checking `reasoningProvider` setting before name heuristics
- **Google OAuth**: Added `newUserCallbackURL` to desktop Google OAuth flow for proper new user registration
- **Linux KDE Taskbar**: Prevented dictation panel from appearing in KDE taskbar
- **Intel Mac CI Builds**: Fixed binary architecture mismatch by installing x64 ffmpeg-static binary and preventing prebuild hooks from deleting x64 binaries on arm64 CI runners (#196)

## [1.5.1] - 2026-02-23

### Added

- **GPU-Accelerated Local Inference**: Vulkan (Windows/Linux) and Metal (macOS) support for llama-server with automatic CPU fallback and GPU status badge in the reasoning model selector
- **CUDA GPU Acceleration for Whisper**: NVIDIA GPU acceleration for local Whisper transcription with automatic GPU detection, upgrade banner for existing users, and shared download progress UI
- **On-Demand Vulkan Download**: Vulkan llama-server binary downloads on-demand when the user opts in, saving 40-46MB from the app installer

### Changed

- **Vulkan Llama-Server Architecture**: Switched from bundling the Vulkan binary to on-demand download into userData, mirroring the Whisper CUDA download pattern

### Fixed

- **macOS Paste Failure**: Replaced osascript-based accessibility check with Electron's native `isTrustedAccessibilityClient()` and fixed focus transfer using hide()+showInactive() instead of blur() on NSPanel (#313)
- **Windows Sherpa-onnx Extraction**: Fixed tar extraction failing on Windows due to GNU tar interpreting drive letter colons as remote host separators — now uses relative paths (#284)
- **macOS Auto-Update Architecture**: Detect Rosetta translation via `sysctl.proc_translated` so Apple Silicon users stuck on an x64 build from older releases self-heal to the native arm64 build on next update

## [1.5.0] - 2026-02-23

### Added

- **Notes System**: Full-featured note-taking built into the control panel
  - Create, edit, and organize notes with a rich Markdown editor
  - Organize notes into custom folders with a default Personal folder
  - Upload audio files for transcription directly into notes
  - Real-time dictation widget for transcribing directly into a note
  - Drag-and-drop to reorder notes and move between folders
  - Guided onboarding flow for first-time notes users
- **AI Actions on Notes**: Apply AI-powered actions to note content
  - Action picker with customizable processing prompts
  - Action manager dialog for creating and editing action templates
  - Processing overlay with live progress feedback
- **Sidebar Navigation**: Redesigned control panel with persistent sidebar
  - New `ControlPanelSidebar` replaces the old tab-based layout
  - Dedicated views for History, Notes, Dictionary, and Settings
  - Collapsible sidebar for more content space
- **Referral Program**: Invite friends to earn free Pro months
  - Referral dashboard with invite tracking and status badges
  - Email invitation flow
  - Animated spectrogram share card with unique referral code
- **New AI Models**: Added Claude 4.6 (Opus), Gemini 3 Flash, and Gemini 3.1 Pro to the model registry
- **Settings Store**: Migrated settings state management to Zustand store for better performance and shared access across components
- **Note Store & Action Store**: New Zustand stores for notes and AI action state

### Changed

- **Control Panel Architecture**: Extracted History, Dictionary, and Settings into standalone views, reducing ControlPanel complexity
- **Settings Refactor**: Extracted bulk of `useSettings` hook logic into `settingsStore.ts` for cleaner separation of concerns
- **UI Polish**: Updated numerous components with improved dark mode support, consistent spacing, and refined typography
- **Locale Updates**: Extended all 10 language files with notes, referral, and sidebar translation keys

### Fixed

- **macOS Auto-Update Architecture**: Detect Rosetta translation via `sysctl.proc_translated` so Apple Silicon users stuck on an x64 build from older releases self-heal to the native arm64 build on next update
- **Linux GTK Crash**: Force GTK3 on Linux startup to avoid GTK symbol crash on systems with GTK4 installed (#291)
- **CI Pipeline**: Added Windows paste binary and key listener download steps to the build workflow (#298)
- **Buy Me a Coffee**: Updated funding link username

## [1.4.11] - 2026-02-13

### Added

- **Japanese Locale**: Full Japanese UI and prompt translations
- **Windows Paste Terminal Detection**: Added kitty to the Windows fast paste binary's terminal class list

### Changed

- **Windows Push-to-Talk Refactor**: Moved PTT state management (hold timing, recording tracking, cooldown) from main process into `windowManager` for cleaner separation and consistency with macOS PTT patterns
- **Audio Recording Reentrancy Guards**: Added lock refs to `useAudioRecording` start/stop to prevent concurrent calls from rapid key presses
- **Synchronous Activation Mode**: `getActivationMode()` is now synchronous (reads from cache), removing unnecessary async overhead in all PTT and hotkey handlers
- **Default Agent Name**: Set default agent name to OpenWhispr

### Fixed

- **Hide vs Minimize**: Dictation panel now consistently hides (rather than minimizing on Windows/Linux) for uniform cross-platform behavior
- **Minimized Window Restore**: Dictation panel restores from minimized state before showing, preventing invisible panel on Windows

## [1.4.10] - 2026-02-13

### Added

- **Deepgram Streaming Liveness Check**: Detects unresponsive warm connections within 2.5s and transparently reconnects with audio replay
- **Batch Transcription Fallback**: If streaming produces no text, automatically falls back to batch transcription via OpenWhispr Cloud
- **Full Locale Codes**: Pass full locale codes (e.g. en-US, zh-CN) to Deepgram instead of stripping to base codes, preserving dialect precision

### Fixed

- **Deepgram Token Expiry**: Fixed token expiry clock resetting on every re-warm cycle, which prevented detection of expired tokens and caused persistent 401 errors
- **Deepgram 401 Recovery**: Invalidate cached tokens on authentication failures so subsequent attempts fetch fresh tokens instead of retrying stale ones

## [1.4.9] - 2026-02-12

### Fixed

- **Deepgram Nova-3 Language Fallback**: Automatically fall back to Nova-2 for languages not yet supported by Nova-3 (e.g., Chinese, Thai), preventing 400 Bad Request errors. Also switches from `keyterm` to `keywords` parameter when using Nova-2.

## [1.4.8] - 2026-02-12

### Added
- **Referral Program**: Invite friends to earn free Pro months with referral dashboard, email invitations, invite tracking with status badges, and animated spectrogram share card with unique referral code
- **Notes System**: Added sidebar navigation with notes system and dictionary view for organizing transcriptions
- **Folder Organization**: Notes can be organized into custom folders with a default Personal folder, folder management UI, and folder-aware note filtering. Upload flow now includes folder selection
- **Internationalization v1**: Full desktop localization across auth, settings, hooks, and UI with centralized renderer locale resources (#258)
- **Chinese Language Split**: Split Chinese into Simplified (zh-CN) and Traditional (zh-TW) with tailored AI instructions and one-time migration for existing users (#267)
- **Russian Interface Language**: Added Russian to interface language options
- **Deepgram Token Refresh & Keyterms**: Proactive token rotation for warm connections before expiry and keyterms pass-through for improved transcription accuracy

### Fixed

- **macOS Non-English Keyboard Paste**: Fixed paste not working on non-English keyboard layouts (Russian, Ukrainian, etc.) by using physical key code instead of character-based keystroke in AppleScript fallback
- **Whisper Language Auto-Detection**: Pass `--language auto` to whisper.cpp explicitly so non-English audio isn't forced to English (#260)
- **Model Download Pipeline**: Inline redirect handling, deferred write stream creation, indeterminate progress bar for unknown sizes, and Parakeet ONNX file validation after extraction
- **Sherpa-onnx Shared Libraries**: Always overwrite shared libraries during download to prevent stale architecture-mismatched binaries, with `--force` support
- **Chinese Translation Fixes**: Minor translation corrections for Chinese interface strings
- **Neon Auth Build Config**: Fixed auth build configuration

## [1.4.7] - 2026-02-11

### Added

- **Deepgram Streaming Transcription**: Migrated real-time streaming transcription from AssemblyAI to Deepgram for improved reliability and accuracy (#249)

### Fixed

- **BYOK After Upgrade**: Prefer localStorage API keys over process.env so Bring Your Own Key mode works correctly after upgrading (#263)
- **PTT Double-Fire Prevention**: Applied post-stop cooldown and press-identity checks to both macOS and Windows push-to-talk handlers
- **Archive Extraction Retry**: Reuse existing archive on extraction retry with improved error handling
- **Email Verification Polling**: Pass email param in verification polling and stop on 401 responses
- **Auth Build Bundling**: Added @neondatabase/auth packages to rollup externals for correct production bundling (#256)
- **Neon Auth Build Config**: Fixed Vite build configuration for Neon Auth packages (#266)

### Changed

- **Build System**: Bumped Node version in build files

## [1.4.6] - 2026-02-10

### Added

- **Robust Model Downloads**: Hardened download pipeline with stall detection, disk space checks, and file validation for more reliable model installs
- **Prompt Handling Improvements**: Improved agent name resolution, prompt studio enhancements, and smarter prompt context assembly
- **Past-Due Subscription Handling**: Users with past-due subscriptions now see clear messaging and recovery options

### Fixed

- **Parakeet Long Audio**: Fixed empty transcriptions for long audio by segmenting input before sending to Parakeet
- **Plus-Addressed Emails**: Reject plus-addressed emails (e.g., user+tag@example.com) during authentication
- **Double-Click Prevention**: Prevent duplicate requests when double-clicking checkout and billing buttons
- **Auth Initialization Race**: Await init-user before completing auth flow and fix missing user dependency

### Changed

- **Startup Performance**: Preload lazy chunks during auth initialization for faster page transitions
- **Code Cleanup**: Removed excess comments and simplified window management logic

## [1.4.5] - 2026-02-09

### Added

- **Dictation Sound Effects Toggle**: New setting to enable/disable dictation audio cues with refined tones (warmer, softer frequencies, gentler attack, distinct start/stop)
- **Toast Notification Redesign**: Redesigned toast notifications as dark HUD surfaces for a more polished look
- **Floating Icon Auto-Hide**: New setting to auto-hide the floating dictation icon
- **Loading Screen Redesign**: Branded loading screen with logo and spinner
- **Discord Support Link**: Added Discord link to the support menu
- **Auth-Aware Routing**: Returning signed-out users now see a re-authentication screen instead of a broken state

### Fixed

- **Dropdown Dark Mode**: Fixed dropdown styling in dark mode
- **Toast Dark Mode**: Fixed toast colouring in dark mode
- **Globe Key Persistence**: Globe key now persists to .env and dictation key syncs to localStorage
- **Globe Listener Cross-Compilation**: Cross-compiled globe listener for x64

### Changed

- **Startup Performance**: Deferred non-critical manager initialization after window creation, lazy-loaded ControlPanel/OnboardingFlow/SettingsModal, converted env file writes to async, extracted SettingsProvider context, and split Radix/lucide into separate vendor chunks
- **Scrollbar Styling**: Subtle transparent-track scrollbar with thinner floating thumb

## [1.4.4] - 2026-02-08

### Fixed

- **AI Enhancement CTA Persistence**: Dismissing the "Enable AI Enhancement" banner now persists to localStorage so it stays hidden across sessions

### Changed

- **Code Cleanup**: Removed excess comments and section dividers in ControlPanel

## [1.4.3] - 2026-02-08

### Added

- **Mistral Voxtral Transcription**: Added Mistral as a cloud transcription provider with Voxtral Mini model and custom dictionary support via context_bias
- **TypeScript Compilation**: Added TypeScript as an explicit dev dependency with project-level `tsconfig.json`

### Fixed

- **Linux Wayland Clipboard**: Persistent clipboard ownership on Wayland so Ctrl+V works reliably after transcription
- **Linux Window Flickering**: Fixed transparent window flickering on Wayland and X11 compositors
- **Windows Modifier-Only Hotkeys**: Support modifier-only hotkeys on Windows via native keyboard hook
- **Update Installation**: Resolved quitAndInstall hang by removing close listeners that block window shutdown during updates
- **Custom System Prompts**: Pass custom system prompt to local and Anthropic BYOK reasoning
- **Audio Cue Audibility**: Improved dictation start/stop audio cue volume
- **Language Selector**: Fixed dropdown positioning and sizing inside settings modal
- **Type Safety**: Tightened Electron IPC callback return types, model picker styles, toast variant types, and event handler signatures across the codebase

### Changed

- **Code Cleanup**: Removed excess comments, section dividers, and redundant JSDoc across components, hooks, and utilities

## [1.4.2] - 2026-02-07

### Fixed

- **AssemblyAI Streaming Reliability**: Fixed real-time WebSocket going silent after idle periods by adding keep-alive pings, readyState validation, re-warm recovery, and connection death handling

## [1.4.1] - 2026-02-07

### Added

- **Runtime .env Configuration**: Environment variables now reload at runtime without requiring app restart
- **Settings Retention on Pro**: Pro subscribers retain their settings when managing their subscription

### Fixed

- **macOS Microphone Permission**: Resolved hardened-runtime mic permission prompt by routing through main-process IPC and unifying API key cache invalidation with event-based AudioManager sync
- **AudioWorklet ASAR Loading**: Inlined AudioWorklet as blob URL to fix module loading failure in packaged ASAR builds
- **Google OAuth Flow**: OAuth now opens in the system browser with deep link callback instead of navigating the Electron window
- **Auth Security Hardening**: Safe JSON parsing, guarded URL constructor, and fixed error information leaks in auth code
- **Deep Link Focus**: Control panel now correctly receives focus when opened via deep link
- **Neon Auth Electron Compatibility**: Routed auth flows through API proxy and fixed Origin header rejection for desktop app
- **Billing Error Visibility**: Checkout and billing errors now surface as toast notifications instead of failing silently
- **Hotkey Persistence**: Added file-based hotkey storage for reliable startup persistence (#181)
- **Email Verification**: Disabled Neon Auth email verification step for smoother onboarding

### Changed

- **Build Optimization**: Binary dependencies are now cached during build for faster CI
- **UI Polish**: Fixed scrollbar styling, provider button styling, and voice recorder icon fill

## [1.4.0] - 2026-02-06

### Added

- **OpenWhispr Cloud**: Cloud-native transcription service — sign in and transcribe without managing API keys
  - Google OAuth and email/password authentication via Neon Auth
  - Email verification flow with polling and resend support
  - Password reset via email magic links
- **Subscription & Billing**: Free and Pro plans with Stripe-powered payments
  - Free plan with rolling weekly word limits (2,000 words/week)
  - Pro plan with unlimited transcriptions
  - 7-day free trial for new accounts with countdown display
  - In-app upgrade prompts when approaching or reaching usage limits
  - Stripe billing portal access for Pro subscribers
- **Usage Tracking**: Real-time usage display with progress bar, color-coded thresholds, and next billing date
- **Account Section in Settings**: Profile display, plan status badge, usage bar, billing management, and sign out
- **Upgrade Prompt Dialog**: When usage limit is reached, offers three paths — upgrade to Pro, bring your own key, or switch to local
- **Cancel Processing Button**: Cancel ongoing transcription processing mid-flight
- **Dynamic Window Resizing**: Window automatically resizes based on command menu and toast visibility
- **Dark Mode Icon Inversion**: Monochrome provider icons now automatically invert in dark mode for better visibility

### Changed

- **Onboarding Redesign**: Auth-first onboarding flow
  - Signed-in users get a streamlined 3-step flow (Welcome → Setup → Activation)
  - Non-signed-in users get a 4-step flow with transcription mode selection
  - Permissions merged into Setup step for signed-in users
- **Transcription Mode Architecture**: Unified mode selection across OpenWhispr Cloud, Bring Your Own Key (BYOK), and Local
  - Signed-in users default to OpenWhispr Cloud
  - Non-signed-in users choose between BYOK and Local
- **Design System Overhaul**: Complete refactor of styling to use design tokens throughout the codebase
  - Button component now uses `text-foreground`, `bg-muted`, `border-border` instead of hardcoded hex values
  - Removed hardcoded classes and inline styles across components
  - Improved button and badge consistency
- **Settings UI Redesign**: Overhauled all settings pages with unified panel system, redesigned sidebar, and extracted permissions section
- **Dark Mode Polish**: Premium button styling, glass morphism toasts, and streamlined visuals
- **App Channel Isolation**: Development, staging, and production channels now use isolated user data directories

### Fixed

- **Light Mode UI Visibility**: Fixed multiple UI elements that were invisible or hard to see in light mode:
  - Settings gear icon in permission cards now uses `text-foreground`
  - Troubleshoot button uses proper foreground color
  - Reset button in developer settings now correctly shows destructive color
  - Settings and Help icons in the toolbar are now properly visible
  - Check for Updates button now renders correctly in light mode
- **Provider Tab Flashing**: Resolved TranscriptionModelPicker tab flashing by extracting ModeToggle component and syncing internal state with props
- **Local Reasoning Model Persistence**: Fixed local reasoning model selection not persisting correctly
- **Parakeet Model Status**: Added dedicated IPC channel for Parakeet model status checks
- **Groq Qwen3 Models**: Removed thinking tokens from Qwen3 models on Groq provider
- **OAuth Session Grace Period**: Automatic session refresh with exponential backoff retry during initial OAuth establishment

## [1.3.3] - 2026-01-28

### Added

- **ONNX Warm-up Inference**: Parakeet server now runs warm-up inference on start to eliminate first-request latency from JIT compilation
- **Startup Preferences Sync**: Renderer startup preferences are now synced to `.env` for server pre-warming on restart

### Changed

- **macOS Tray Behavior**: Hide to tray on macOS for consistent cross-platform behavior

### Fixed

- **macOS Launch Crash**: Added `disable-library-validation` entitlement to resolve macOS launch crash (#120)
- **Reasoning Model Default**: Fixed `useReasoningModel` not correctly defaulting to enabled by persisting useLocalStorage defaults and aligning direct reads
- **Windows Non-ASCII Usernames**: Resolved whisper-server crash on Windows with non-ASCII usernames by pre-converting audio to WAV and routing temp files through ASCII-safe directory
- **Windows Paths with Spaces**: Fixed temp directory fallback to also detect paths with spaces on Windows

## [1.3.2] - 2026-01-27

### Changed

- **Linux Paste Tools**: Prefer xdotool over ydotool for better compatibility

### Fixed

- **Windows Zip Extraction**: Use tar instead of PowerShell Expand-Archive for zip extraction on Windows to avoid issues with special characters

## [1.3.1] - 2026-01-27

### Changed

- **Download System Refactor**: Consolidated model download logic into shared utilities with resume support, retry logic, abort signals, and improved installing state UI
- **Throttled Progress Display**: Whisper model download progress updates are now throttled for smoother UI

## [1.3.0] - 2026-01-26

### Added

- **NVIDIA Parakeet Support**: Fast local transcription via sherpa-onnx runtime with INT8 quantized models
  - `parakeet-tdt-0.6b-v3`: Multilingual (25 languages), ~680MB
- **Windows Push-to-Talk**: Native Windows key listener with low-level keyboard hook for true push-to-talk functionality
  - Supports compound hotkeys like `Ctrl+Shift+F11` or `CommandOrControl+Space`
  - Prebuilt binary automatically downloaded from GitHub releases
  - Fallback to tap mode if binary unavailable
- **Custom Dictionary**: Improve transcription accuracy for specific words, names, and technical terms
  - Add custom words through Settings → Custom Dictionary
  - Words are passed as hints to Whisper for better recognition
  - Works with both local and cloud transcription
- **GitHub Actions Workflow**: Automated CI workflow to build and release Windows key listener binary
- **Shared Download Utilities**: New `scripts/lib/download-utils.js` module with reusable download, extraction, and GitHub release fetching functions

### Changed

- **Download Scripts Refactored**: All download scripts now use shared utilities for consistency
- **GitHub API Authentication**: Download scripts support `GITHUB_TOKEN` to avoid API rate limits in CI
- **Debug Logging Cleanup**: Extracted common window loading code and cleaned up debug logging

### Fixed

- **GNOME Wayland Hotkey Improvements**: Improved hotkey handling on GNOME Wayland
- **Hotkey Persistence**: Fixed hotkey selection not persisting correctly
- **Custom Endpoint API Keys**: Fixed custom endpoint API keys not persisting to `.env` file
- **Custom Endpoint State**: Fixed custom endpoint using shared state instead of its own
- **Linux Stale Hotkey Registrations**: Clear stale hotkey registrations on startup on Linux
- **Wayland XWayland Paste**: Try xdotool on Wayland when XWayland is available
- **llama-server Libraries**: Bundle llama-server shared libraries and search from extract root for varying archive structures
- **STT/Reasoning Debug Logging**: Added missing debug logging for STT and reasoning pipelines

## [1.2.16] - 2026-01-24

### Fixed

- **App Startup Hang**: Fixed app initialization timing issues with Electron 36+
- **Manager Initialization**: Deferred manager initialization until after `app.whenReady()` to prevent hangs
- **Debug Logger Initialization**: Deferred debugLogger file initialization until `app.whenReady()`
- **Config Bundling**: Fixed missing config files in production builds
- **whisper.cpp Binary Version**: Updated whisper.cpp release names and bumped binary version

## [1.2.15] - 2026-01-22

### Added

- **ydotool Fallback for Linux**: Added ydotool as additional fallback option for clipboard paste operations on Linux systems

### Changed

- **Unified Prompt System**: Refactored to single intelligent prompt system for improved consistency and maintainability
- **whisper.cpp Remote**: Refactored remote whisper.cpp integration for better reliability

## [1.2.14] - 2026-01-22

### Added

- **Troubleshooting Mode**: New debug logging section in settings with toggle for detailed diagnostic logs, log file path display, and direct folder access for easier support
- **Custom Transcription Endpoint**: Support for custom OpenAI-compatible transcription endpoints with configurable base URLs
- **Enhanced Clipboard Debugging**: Detailed clipboard operation logging for diagnosing paste issues across platforms

### Changed

- **API Key Management**: Consolidated and refactored API key persistence with improved .env file handling and recovery mechanisms
- **Local Network Detection**: Refactored URL detection into reusable utility for better code organization
- **Electron Builder**: Updated to latest version for improved build performance

### Fixed

- **Windows/Linux Taskbar**: Prevented dual taskbar entries on Windows and Linux by properly configuring window behavior
- **Single Instance Lock**: Enforced single instance lock with cleaner window state checks
- **Model Provider Consistency**: Removed redundant fallbacks and ensured consistent use of getModelProvider()
- **Cross-env Support**: Fixed Windows compatibility in pack script using cross-env
- **Linux X11 Paste**: Improved paste reliability by capturing target window ID upfront with windowactivate --sync, added xdotool type fallback for terminals
- **Tray Minimize**: Fixed minimize to tray functionality

## [1.2.12] - 2026-01-20

### Added

- **LLM Download Cancellation**: Added ability to cancel in-progress local LLM model downloads with throttled progress updates to prevent UI flashing

### Changed

- **Gemini Model Updates**: Updated Gemini models to latest versions
- **Linux Wayland Improvements**: Improved Wayland paste detection with GNOME-specific handling and XWayland fallback support
- **whisper.cpp CUDA Support**: Updated whisper.cpp download script to include CUDA-enabled binaries

### Fixed

- **Windows Paste Delay**: Adjusted paste delay timing on Windows for more reliable text insertion
- **Blank Audio Prevention**: Fixed issue where blank/silent audio recordings would paste empty text
- **Newline Handling**: Fixed newline formatting issues in transcribed text

## [1.2.11] - 2026-01-18

### Fixed

- **ASAR Path Resolution**: Fixed path resolution issues for bundled resources in packaged builds
- **Update Checker**: Fixed auto-update checker initialization
- **Build Includes**: Ensured services and models are properly included in production builds
- **OS Module Import**: Fixed OS module import ordering

## [1.2.10] - 2026-01-17

### Fixed

- **Streaming Backpressure**: Fixed proper streaming backpressure handling in audio processing
- **Quit and Install**: Fixed update installation on app quit

## [1.2.9] - 2026-01-17

### Fixed

- **Path Resolution**: Improved path resolution for better cross-platform compatibility

## [1.2.8] - 2026-01-16

### Added

- **Microphone Input Selection**: Choose your preferred microphone input device in settings, with built-in mic preference to prevent Bluetooth audio interruptions
- **Push to Talk Mode**: New recording mode option alongside the existing toggle mode
- **Hotkey Listening Mode**: Prevents conflicts when capturing new hotkeys by temporarily disabling the global hotkey
- **Hotkey Fallback System**: Automatic fallback with user notifications when preferred hotkey is unavailable
- **Cross-Platform Accessibility Settings**: Quick access to system accessibility settings on macOS

### Changed

- **Streamlined Onboarding**: Removed redundant "How it Works" section, success dialogs, and manual save buttons for a smoother setup experience
- **Improved Select Styling**: Enhanced dropdown select component appearance

### Fixed

- **FFmpeg Availability Types**: Corrected type definitions and optimized whisper-cpp download process
- **Whisper Models Path**: Fixed model storage path resolution
- **Better Path Resolution**: Improved error handling for file paths
- **Open Mic Settings**: Fixed system settings link for microphone configuration

## [1.2.7] - 2026-01-13

### Added

- **Whisper Server HTTP Mode**: Added persistent whisper-server for faster repeated transcriptions with automatic CLI fallback
- **Pipeline Timing Instrumentation**: Added detailed timing logs for each stage of the transcription pipeline
- **Whisper Server Pre-warming**: Server pre-warms on startup for faster first transcription

### Changed

- **Windows Clipboard**: Reduced clipboard delays for faster text pasting on Windows

### Fixed

- **Windows Update Install**: Simplified Windows update installation by using silent mode and removing redundant before-quit handling
- **Mac Build Workflows**: Fixed CI/CD to run separate workflows for Mac builds
- **Mac DMG Build Race Condition**: Fixed release workflow DMG build failure caused by concurrent arm64/x64 builds mounting same volume
- **Windows Download Script**: Fixed PowerShell Expand-Archive failure with bracket characters in directory names

## [1.2.6] - 2026-01-13

### Changed

- **Settings Layout**: Moved settings navigation to left side on Windows and Linux for improved consistency

### Fixed

- **Linux Whisper Detection**: Fixed issue where Python-based Whisper could be used instead of whisper.cpp on Linux systems

## [1.2.5] - 2026-01-13

### Added

- **Model Validation**: Added validation when deleting or loading Whisper models to ensure model integrity
- **Download Cancellation**: Added ability to cancel in-progress model downloads in whisper pickers
- **Windows Paste Performance**: Added nircmd for faster text pasting on Windows

### Fixed

- **EventEmitter Memory Leak**: Fixed memory leak caused by duplicate listener registration in useUpdater hook across ControlPanel and SettingsPage components
- **FFmpeg Path Resolution**: Fixed FFmpeg path resolution in unpacked ASAR for local whisper.cpp transcription

### Changed

- **UI Cleanup**: Removed redundant UI elements for a cleaner interface

## [1.2.4] - 2026-01-13

### Changed

- **whisper.cpp Packaging**: Moved whisper.cpp binaries from ASAR to extraResources for improved reliability and faster startup

### Fixed

- **Package Lock Sync**: Fixed package-lock.json synchronization with package.json dependencies

## [1.2.3] - 2026-01-13

### Added

- **Extended Hotkey Support**: Added numpad keys, media keys, and additional special keys (Pause, ScrollLock, PrintScreen, NumLock) for hotkey selection
- **Improved Hotkey Error Messages**: Registration failures now include helpful suggestions for alternative hotkeys

### Changed

- **Linux Paste Tools**: Only show paste tools installation prompt on Linux when tools are not available

### Fixed

- **Hotkey Debugging**: Added comprehensive debug logging to hotkey manager for troubleshooting registration issues

## [1.2.2] - 2026-01-13

### Fixed

- **React Version Mismatch**: Fixed blank screen caused by incompatible React and React-DOM versions in package-lock.json

## [1.2.1] - 2026-01-13

### Fixed

- **Blank Screen on Upgrade**: Fixed white screen issue for users upgrading from older versions with different onboarding step counts. The onboarding step index is now properly clamped to valid range.

## [1.2.0] - 2026-01-13

### Added

- **Delete All Whisper Models**: New option to delete all downloaded Whisper models at once
- **Model Deletion Confirmation**: Added confirmation dialog when deleting models in settings

### Changed

- **Migrated to whisper.cpp**: Replaced Python-based Whisper with native whisper.cpp for faster, more reliable transcription
  - No longer requires Python installation
  - WebM-to-WAV audio conversion built-in
  - Significantly improved startup and transcription speed
- **Streamlined Onboarding**: Simplified setup flow with fewer steps now that Python is not required
- **Download Cancellation**: Added ability to cancel in-progress model downloads
- **CI/CD Updates**: Updated build and release workflows

### Fixed

- **IPC Handler**: Fixed broken IPC handler for model operations
- **Logging**: Standardized logging across the application
- **React Hook Dependencies**: Improved React hook dependency arrays for better performance
- **Button Styling**: Fixed button styling consistency across the application

### Removed

- **Python Dependency**: Removed Python requirement and all related installation code
- **whisper_bridge.py**: Removed Python-based Whisper bridge in favor of native whisper.cpp

## [1.1.2] - 2026-01-12

### Added

- **Linux Package Dependencies**: Recommended xdotool, wtype, and python3 packages for Linux users

### Fixed

- **Python Installation Race Condition**: Fixed race condition in Python installation check that could cause installation to fail or hang

## [1.1.1] - 2026-01-12

### Added

- **Cross-Platform Paste Tools Detection**: Onboarding now detects and guides users through installing paste tools on Linux and Windows with auto-grant accessibility

### Changed

- **Qwen Model Compatibility**: Disabled thinking mode for Qwen models on Groq to prevent compatibility issues
- **Model Registry Refactor**: disableThinking flag now uses the centralized model registry
- **Consolidated ColorScheme Types**: Removed redundant default exports and cleaned up inline font styles
- **Provider Icons**: Use static imports for provider icons to fix Vite bundling issues

### Fixed

- **Recording Cancellation**: Restored cancel recording functionality that was accidentally removed
- **Model Downloads**: Implemented atomic downloads with temp file pattern and robust cleanup handling for cross-platform reliability
- **Incomplete Download Prevention**: Model file size validation now prevents incomplete downloads from showing as complete
- **Windows PowerShell Performance**: Optimized paste startup time on Windows

## [1.1.0] - 2026-01-10

### Added

- **Compound Hotkey Support**: Use multi-key combinations like `Cmd+Shift+K` or `Ctrl+Alt+D` for dictation
- **Groq API Integration**: Ultra-fast AI inference with Groq's cloud API
- **Auto-Update UI**: Download progress bars and install button in settings
- **Recording Cancellation**: Cancel an in-progress recording without transcribing
- **Release Notes Viewer**: Markdown-rendered release notes in settings

### Changed

- **Major Hotkey Refactor**: Complete rewrite of hotkey selection with improved reliability and validation
- **Consolidated Model Registry**: Single source of truth for all AI models (`modelRegistryData.json`)
- **Unified Model Picker**: Reusable component for both transcription and reasoning model selection
- **Improved Latency Logging**: Numbered stage logs for recording, transcription, reasoning, and paste timing
- **Reduced Paste Delay**: Lowered from 100ms to 50ms for faster text insertion
- **Code Quality**: Added ESLint, Prettier for JS/TS, and Ruff for Python

### Fixed

- **Windows 11 Compatibility**: Fixed PATH separator, cache directories, and process termination
- **Python Virtual Environment**: Fixed race condition and added Arch Linux venv support
- **Microphone Detection**: Improved onboarding flow for missing inputs with deep-linking to system settings
- **Recording State Alignment**: Recording now aligns to MediaRecorder's actual start/stop events
- **Caching Optimizations**: Cached accessibility, paste tool, and FFmpeg checks to reduce process spawns
- **Window Titles**: Electron window titles now set correctly after page load

## [1.0.15] - 2026-01-05

### Added

- Button to fully quit OpenWhispr processes from the application
- Linux terminal detection with automatic paste key switching (Ctrl+Shift+V for terminals)

### Changed

- Standardized logging on log levels with renderer IPC and `.env` refresh for consistent debug output

### Fixed

- Use `kdotool` for Wayland terminal detection, improving clipboard paste reliability
- Increased delay before restoring clipboard to avoid race conditions during paste operations
- Persist OpenAI key before onboarding test to prevent key loss during setup
- Windows Python discovery now correctly handles output parsing
- Keep FFmpeg debug schema as boolean type
- Fixed OpenWhispr documentation paths
- Windows: Resolved issue #16 with WAV validation, registry-based Python detection, and normalized FFmpeg paths

## [1.0.13] - 2025-12-24

### Added

- Enhanced Linux support with Wayland compatibility, multiple package formats (AppImage, deb, rpm, Flatpak), and native window controls
- Auto-detect existing Python during onboarding and gate the installer with a recheck option
- "Use Existing Python" skip flow to onboarding with confirmation dialog

### Changed

- Reuse audio manager and stabilize dictation toggle callback to fix recording latency
- Add cleanup functions to IPC listeners to prevent memory leaks
- Make Flatpak opt-in for local builds only

### Fixed

- Optimized transcription pipeline with caching, batched reads, and non-blocking operations for improved performance
- Reference error in settings page
- Removed redundant audio listener causing unnecessary processing
- Added IPC listener cleanup to prevent memory leaks
- Performance improvements: removed duplicate useEffect, fixed blur causing re-renders

### CI/CD

- Add caching for Electron and Flatpak downloads
- Add Flatpak runtime installation to workflow
- Add Linux packaging dependencies to GitHub Actions workflow

## [1.0.12] - 2025-11-13

### Added

- Added `scripts/complete-uninstall.sh` plus a new TROUBLESHOOTING guide so you can collect arch diagnostics, clean caches, and reset permissions before reinstalling stubborn builds.
- Control Panel history now auto-refreshes through a shared store and IPC events, so new, deleted, or cleared transcripts sync instantly without a manual refresh.
- Distribution artifacts now include both Apple Silicon and Intel macOS DMG/ZIP outputs, and the README documents Debian/Ubuntu packaging along with optional `xdotool` support.

### Changed

- The onboarding flow now validates dictation hotkeys before letting you continue, remembers whether cloud auth was skipped, and only persists sanitized API keys once supplied.
- History entries normalize timestamps and no longer run the removed legacy text cleanup helper, so the UI shows the exact Whisper output that was saved.

### Fixed

- Local Whisper now finds Python on Windows more reliably by scanning typical install paths, honoring `OPENWHISPR_PYTHON`, and surfacing actionable ENOENT guidance.
- Whisper installs automatically retry pip operations that hit PEP‑668, TOML, or permission errors, sanitizing the output and falling back to `--user` + legacy resolver when needed.

## [1.0.11] - 2025-10-13

### Added

- Settings, onboarding, and the AI model selector now accept OpenAI-compatible custom base URLs for both transcription and reasoning providers, complete with validation and reset helpers.
- Windows now gets full tray behavior: closing the control panel hides it to the tray, left-click reopens it, and the UI adds a native close button.

### Changed

- ReasoningService sends both `input` and `messages` payloads and automatically falls back between `/responses` and `/chat/completions` so older OpenAI-compatible endpoints keep working.

### Fixed

- Successful endpoint detection is cached per base URL, so the app remembers whether to call `/responses` or `/chat/completions` instead of retrying the wrong path forever.
- Custom endpoint fields now enforce HTTPS (with localhost as the lone exception) across the UI and services, preventing API keys from ever leaving over plain HTTP.

## [1.0.10] - 2025-10-07

### Added

- Added a `compile:globe` build step that emits a macOS Globe listener binary into `resources/bin` before every dev, pack, or dist command so the hotkey ships with all builds.

### Fixed

- Globe key failures now raise a macOS dialog, verify the bundled binary is executable, and kill/restart the listener cleanly so the shortcut survives packaging.

## [1.0.9] - 2025-10-07

### Changed

- Simplified the release workflow by removing the bespoke GitHub release job and letting electron-builder upload draft releases directly.

## [1.0.8] - 2025-10-03

### Fixed

- Globe/Fn hotkey reliability improved by showing the dictation panel before toggling, making focus optional, and surfacing listener spawn errors instead of failing silently.

## [1.0.7] - 2025-10-03

### Added

- Settings update controls now show download progress bars, install countdowns, and clearer messaging while fetching or installing new builds.

### Changed

- Auto-update internals now track listeners, cache the last release metadata, and keep auto-download/auto-install disabled until the user explicitly triggers an update, eliminating the previous memory leaks.

### Fixed

- `Install & Restart` now emits `before-quit`, enables `autoInstallOnAppQuit`, logs progress, and calls `quitAndInstall(false, true)` so updates actually apply when quitting or pressing the button.

## [1.0.6] - 2025-09-11

### Added

- **Dictation Panel Command Menu**: Clicking the floating panel reveals quick actions, including a one-click "Hide this for now" option.
- **macOS Globe Key Support**: Added a lightweight Swift listener so the Globe/Fn key can toggle dictation across the system.
- **Globe Key Selection UI**: Settings and onboarding keyboards now include a dedicated Globe key option.
- **Hotkey Validation**: Settings and onboarding now verify shortcut registration immediately, alerting users when a key can’t be bound.
- **Model Cache Cleanup**: Added an in-app command (and installer/uninstaller hooks) to delete all cached Whisper models.
- **Tray Controls**: macOS tray menu gained quick actions to show or hide the dictation panel.

### Changed

- **Dictation Overlay Placement**: Window now anchors to the active workspace's bottom-right corner with a safety margin, preventing it from sliding off-screen on multi-monitor setups.
- **Dictation Overlay Canvas**: Enlarged the floating window so tooltips, menus, and error states render without being clipped while keeping click-through behaviour outside interactive elements.
- **Keyboard UX**: Virtual keyboard hides macOS-exclusive keys on Windows/Linux and standardises hotkey labels.

### Fixed

- **macOS Window Lifecycle**: Ensured the dictation panel keeps the app visible in Dock and Command-Tab while retaining floating behaviour across spaces.
- **Control Panel Stability**: Reworked close/minimize handling so the panel stays interactive when switching apps and reopens cleanly without spawning duplicate windows.
- **Always-On-Top Enforcement**: Centralised the logic that reapplies floating window levels, eliminating redundant timers and focus quirks.
- **Menu Labelling**: macOS application menu items now display the correct OpenWhispr casing instead of "open-whispr".
- **Non-mac Hotkey Guard**: Prevented the mac-only Globe shortcut from being saved on Windows/Linux.

## [1.0.5] - 2025-09-10

### Fixed

- **Build System**: Fixed native module signing conflicts on macOS
  - Added `npmRebuild: true` to force rebuild of native modules during packaging
  - Added `buildDependenciesFromSource: true` to compile native dependencies from source
  - Added `better-sqlite3` to `asarUnpack` array to properly unpack SQLite3 native module
  - Resolves "different Team IDs" error when launching notarized macOS apps
- **CI/CD Pipeline**: Fixed automated release workflow issues
  - Removed automatic version update step from release workflow (version should be set before tagging)
  - Added `contents: write` permission to allow workflow to create GitHub releases
  - Fixes "Resource not accessible by integration" error during releases

### Technical Details

- This is a maintenance release focusing on build reliability and deployment infrastructure
- No feature changes or user-facing functionality updates
- All changes related to packaging, signing, and automated release processes

## [1.0.4] - 2025-09-09

### Added

- **Multi-Provider AI Support**: Integrated three major AI providers for text processing
  - OpenAI: Complete model suite including:
    - GPT-5 Series (Nano/Mini/Full) - Latest generation with deep reasoning
    - GPT-4.1 Series (Nano/Mini/Full) - Enhanced coding, 1M token context, June 2024 knowledge
    - o-series (o3/o3-pro/o4-mini) - Advanced reasoning models with extended thinking time
    - GPT-4o/4o-mini - Multimodal models with vision support
  - Anthropic: Claude Opus 4.1, Sonnet 4, and 3.5 variants for frontier intelligence
  - Google: Gemini 2.5 Pro/Flash/Flash-Lite and 2.0 Flash for advanced processing
- **OpenAI Responses API Integration**: Migrated from Chat Completions to the new Responses API
  - Simplified request format with `input` array instead of `messages`
  - New response parsing for `output` items with typed content
  - Automatic handling of model-specific requirements
  - Better support for GPT-5 and o-series reasoning models
- **Enhanced Reasoning Service**: Complete TypeScript rewrite with provider abstraction
  - Automatic provider detection based on selected model
  - Secure API key caching with TTL
  - Unified retry strategies across all providers
  - Provider-specific token optimization (up to 8192 for Gemini)
- **Comprehensive Debug Logging**: Enhanced reasoning pipeline with stage-by-stage logging
  - Provider selection and routing logs
  - API key retrieval and validation logs
  - Request/response details for all providers
  - Error tracking with full stack traces
- **Improved Settings UI**: Comprehensive API key management for all providers
  - Color-coded provider sections (OpenAI=green, Anthropic=purple, Gemini=blue)
  - Inline API key validation and secure storage
  - Provider-specific model selection with descriptions

### Changed

- **Default AI Model**: Updated from GPT-3.5 Turbo to GPT-4o Mini for cost-efficient multimodal support
- **Model Updates**: Refreshed all AI models to their latest 2025 versions
  - OpenAI: Added GPT-5 family (released August 2025), migrated to Responses API
  - Anthropic: Updated to Claude Opus 4.1 and Sonnet 4, fixed model naming
  - Gemini: Added latest 2.5 series models, increased token limits
- **ReasoningService**: Migrated from JavaScript to TypeScript for better type safety
- **API Endpoint Updates**:
  - OpenAI: Migrated from `/v1/chat/completions` to `/v1/responses`
  - Request format simplified for better performance
  - Response parsing updated for new output structure
- **Model Configuration Improvements**:
  - Fixed Anthropic model names (using hyphens instead of dots)
  - Increased Gemini 2.5 Pro token limits (2000 minimum)
  - Removed temperature parameter for GPT-5 and o-series models
- **Documentation**: Updated CLAUDE.md, README.md with comprehensive provider information

### Fixed

- **API Key Persistence**: All provider keys now properly save to `.env` file
  - Added `saveAllKeysToEnvFile()` method for consistent persistence
  - Keys reload automatically on app restart
  - Fixed Gemini and Anthropic key storage issues
- **CORS Issues**: Anthropic API calls now route through IPC handler
  - Avoids browser CORS restrictions in renderer process
  - Proper error handling in main process
- **Empty Response Handling**: Fixed "No text transcribed" error when AI returns empty
  - Falls back to original text when API returns nothing
  - Properly handles edge cases in response parsing
- **Parameter Compatibility**: Fixed OpenAI API parameter errors
  - GPT-5 models use simplified parameters (no max_tokens)
  - o-series models configured without temperature
  - Older models retain full parameter support

### Technical Improvements

- Added Gemini API integration with proper authentication flow
- Implemented SecureCache utility for API key management
- Enhanced IPC handlers for multi-provider support
- Updated environment manager with Gemini key storage
- Improved error handling with provider-specific messages
- Added comprehensive retry logic with exponential backoff
- Enhanced error messages with detailed logging
- Better fallback strategies for API failures
- Improved response validation and parsing
- Centralized API configuration in constants file
- Unified debugging system across all providers

## [1.0.3] - 2024-12-20

### Added

- **Local AI Models**: Integration with community models for complete privacy
  - Support for Llama, Mistral, and other open-source models
  - Local model management UI with download progress
  - Automatic model validation and testing
- **Enhanced Security**: Improved API key storage and management
  - System keychain integration where available
  - Encrypted localStorage fallback
  - Automatic key rotation support

### Fixed

- Resolved issues with Whisper model downloads on slow connections
- Fixed clipboard pasting reliability on Windows 11
- Improved error messages for better debugging
- Fixed memory leaks in long-running sessions

### Changed

- Optimized audio processing pipeline for 30% faster transcription
- Reduced app bundle size by 15MB through dependency optimization
- Improved startup time by lazy-loading heavy components

## [1.0.2] - 2024-12-19

### Added

- **Automatic Python Installation**: The app now detects and offers to install Python automatically
  - macOS: Uses Homebrew if available, falls back to official installer
  - Windows: Downloads and installs official Python with proper PATH configuration
  - Linux: Uses system package manager (apt, yum, or pacman)
- **Enhanced Developer Experience**:
  - Added MIT LICENSE file
  - Improved documentation for personal vs distribution builds
  - Added FAQ section to README
  - Added security information section
  - Clearer prerequisites and setup instructions
  - Added comprehensive CLAUDE.md technical reference
- **Dock Icon Support**: App now appears in the dock with activity indicator
  - Changed LSUIElement from true to false in electron-builder.json
  - App shows in dock on macOS with the standard dot indicator when running

### Changed

- Updated supported language count from 90+ to 58 (actual count in codebase)
- Improved README structure for better open source experience

## [1.0.1] - 2024-XX-XX

### Added

- **Agent Naming System**: Personalize your AI assistant with a custom name for more natural interactions
  - Name your agent during onboarding (step 6 of 8)
  - Address your agent directly: "Hey [AgentName], make this more professional"
  - Update agent name anytime through settings
  - Smart AI processing distinguishes between commands and regular dictation
  - Clean output automatically removes agent name references
- **Draggable Interface**: Click and drag the dictation panel to any position on screen
- **Dynamic Hotkey Display**: Tooltip shows your actual hotkey setting instead of generic text
- **Flexible Hotkey System**: Fixed hardcoded hotkey limitation - now fully respects user settings

### Changed

- **[BREAKING]** Removed click-to-record functionality to prevent conflicts with dragging
- **UI Behavior**: Recording is now exclusively controlled via hotkey (no accidental triggering)
- **Tooltip Text**: Shows "Press {your-hotkey} to speak" with actual configured hotkey
- **Cursor Styles**: Changed to grab/grabbing cursors to indicate draggable interface

### Fixed

- **Hotkey Bug**: Fixed issue where hotkey setting was stored but not actually used by global shortcut
- **Documentation**: Updated all docs to reflect current UI behavior and hotkey system
- **User Experience**: Eliminated confusion between drag and click actions

### Technical Details

- **Agent Naming Implementation**:
  - Added centralized agent name utility (`src/utils/agentName.ts`)
  - Enhanced onboarding flow with agent naming step
  - Updated ReasoningService with context-aware AI processing
  - Added agent name settings section with comprehensive UI
  - Implemented smart prompt generation for agent-addressed vs regular text
- Added IPC handlers for dynamic hotkey updates (`update-hotkey`)
- Implemented window-level dragging using screen cursor tracking
- Added real-time hotkey loading from localStorage in main dictation component
- Updated WindowManager to support runtime hotkey changes
- Added proper drag state management with smooth 60fps window positioning
- **Code Organization**: Extracted functionality into dedicated managers and React hooks:
  - HotkeyManager, DragManager, AudioManager, MenuManager, DevServerManager
  - useAudioRecording, useWindowDrag, useHotkey React hooks
  - WindowConfig utility for centralized window configuration
  - Reduced WindowManager from 465 to 190 lines through composition pattern

## [0.1.0] - 2024-XX-XX

### Added

- Initial release of OpenWhispr (formerly OpenWispr)
- Desktop dictation application using OpenAI Whisper
- Local and cloud-based speech-to-text transcription
- Real-time audio recording and processing
- Automatic text pasting via accessibility features
- SQLite database for transcription history
- macOS tray icon integration
- Global hotkey support (backtick key)
- Control panel for settings and configuration
- Local Whisper model management
- OpenAI API integration
- Cross-platform support (macOS, Windows, Linux)

### Features

- **Speech-to-Text**: Convert voice to text using OpenAI Whisper
- **Dual Processing**: Choose between local processing (private) or cloud processing (fast)
- **Model Management**: Download and manage local Whisper models (tiny, base, small, medium, large)
- **Transcription History**: View, copy, and delete past transcriptions
- **Accessibility Integration**: Automatic text pasting with proper permission handling
- **API Key Management**: Secure storage and management of OpenAI API keys
- **Real-time UI**: Live feedback during recording and processing
- **Global Hotkey**: Quick access via customizable keyboard shortcut
- **Database Storage**: Persistent storage of transcriptions with SQLite
- **Permission Management**: Streamlined macOS accessibility permission setup

### Technical Stack

- **Frontend**: React 19, Vite, TailwindCSS, Shadcn/UI components
- **Backend**: Electron 36, Node.js
- **Database**: better-sqlite3 for local storage
- **AI Processing**: OpenAI Whisper (local and API)
- **Build System**: Electron Builder for cross-platform packaging

### Security

- Local-first approach with optional cloud processing
- Secure API key storage and management
- Sandboxed renderer processes with context isolation
- Proper clipboard and accessibility permission handling
