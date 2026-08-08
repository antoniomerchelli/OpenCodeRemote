# PIANO TEST DEFINITIVO — OpenCode Remote iOS

**Stato:** ATTIVO (8 Ago 2026). Piano ricreato e reso persistente dopo che il
dettaglio F0–F9 originale è andato perso con la pulizia dello scratchpad (S20).
Questo file è la **fonte di verità** per il completamento del progetto; la
checklist va aggiornata a ogni fase completata.

**Ground truth wire:** `.opencode/memory/lessons.md` + `RealWireFixturesTests.swift`.
NON usare i documenti storici a root (obsoleti).

---

## 0. Stato di partenza (verificato il 8 ago 2026)

- `swift build` ✅ · `swift test` **394/394** ✅ · `swift run LiveE2E` **27/27** ✅
- Server reale 1.18.15 attivo su `127.0.0.1:4096`
- MockServer: ~28 rotte implementate; client v2: ~50 metodi (gap ~12 rotte)
- Git: 1 commit locale non pushatto (`cb10bac`) + working tree S22 + 17 file di
  test untracked — **da committare e pushare (Fase 1)**

---

## 1. Fasi

### F0–F3 — Fondamenta e fixture wire ✅ FATTE (S20–S21)
- F0: detection protocollo v1/v2, tassonomia errori (S20)
- F1: client REST v2 completo (`OpenCodeAPIClientV2`, ~50 metodi) (S20)
- F2: streaming SSE v2 + coalescer + reconnect + stress test (S20)
- F3: fixture wire reali 1.18.15 congelati (`RealWireFixturesTests`, 13 test) (S21)
- Bonus: LiveE2E esteso 13→27 check contro server reale (S22)

### Fase 1 — Igiene repository (prima di tutto)
**Deliverable:** repo pulito, tutto committato e pushatto.
- [ ] Commit `cb10bac` (fix Red Team) → push
- [ ] Commit working tree S22 (fix wire model v2/v1, LiveE2E 27 check, MockServer, docs)
- [ ] Commit 17 file di test untracked (mai committati — rischio perdita)
- [ ] Decidere sorte `AGENTS.md` (artefatto `/init` ma usato come istruzioni di progetto)
- [ ] Verificare `Package.swift` senza target fantasma
- [ ] Verifica: `swift build` + `swift test` post-commit

### Fase 2 — F4: Integration MockServer completa (happy + error)
**Deliverable:** ogni rotta del client v2 ha una controparte mock con happy path
e almeno un error path; test di integrazione per ciascuna.
- [x] Gap analysis finale rotte client v2 vs mock (deep-researcher)
- [x] Rotte mancanti da aggiungere al mock (~12, da confermare):
  `compact`, `wait`, `context`, `fork`, `summarize`, `share`, `unshare`,
  `modelDefault`, `providerGet`, `permissionSaved`/`permissionRemoveSaved`,
  `fileList`, `fileFind`
- [x] Error path: 404 sessione/pty inesistente, 400 body invalido, HTML fallback
- [x] Test di integrazione per ogni rotta nuova (mock + client reale)
- [x] `swift test` verde (421: 394 + 27 nuovi F4)
- **Vincoli wire F3 da rispettare:** history = eventi (non messaggi), `cost`
  array, raw non cattura chiavi extra, `prompt` è oggetto `{text}`,
  `model` chiavi speculari v2 `{id, providerID}` vs v1 `{providerID, modelID}`,
  body 400/500 con messaggio in `data.message` (v1) / top-level `message` (v2),
  `performNoContent` richiede body `{}`.

### Fase 3 — F7: Fix robustezza residui
**Deliverable:** i rischi noti di robustezza chiusi o documentati come scelte.
- [ ] **SSE v1 idle watchdog** (stream v1 senza heartbeat: il client non deve
  morire per idle timeout)
- [ ] **Timeout flat 30s v1** → timeout per-funzione configurabile/adeguato
- [ ] **Race AppState più profonda** (connect/disconnect multi-generazione: audit
  di tutti i path async oltre a `connectV2`/`disconnectV2`)
- [ ] **Rischio wire aperto (Red Team S22):** chiave `model` della v2
  shell/command — su server che implementa la v2, verificare che accetti `id`.
  Fino a prova contraria: documentare + fallback v1 già corretto
- [ ] Audit force-unwrap residui (`!` runtime) → 0
- [ ] Audit secret hardcoded / credenziali in log

### Fase 4 — F6: Stress esteso
**Deliverable:** suite stress ampliata sui path coperti in F4/F7, 3x verde.
- [ ] Stress su pty pool (create/update/remove concorrenti)
- [ ] Stress su revert staging (stage/clear/commit ripetuti)
- [ ] Stress su file list/find (payload grandi)
- [ ] Stress su eviction store (sessioni > limite, rilettura)
- [ ] 3 run consecutivi verdi (niente flaky)

### Fase 5 — F8: CI + View-model extraction
**Deliverable:** CI verde su ogni push; UI decouplata da AppState.
- [ ] **GitHub Actions** (macos-latest, `swift build` + `swift test`;
  eventualmente LiveE2E opzionale con server mock)
- [ ] **View-model extraction**: `AppState` → view-model per le schermate
  principali (chat, terminal, file explorer, settings) per testabilità
- [ ] Test per i view-model estratti

### Fase 6 — F9: Verifica finale multi-livello + Red Team
**Deliverable:** chiusura certificata del piano.
- [ ] `swift build` + `swift test` (394+ nuovi) verdi
- [ ] Suite stress 3x verde
- [ ] `swift run LiveE2E` 27/27+ contro server reale
- [ ] **Red Team (code-reviewer)** su tutte le modifiche della sessione
- [ ] MockServer: smoke di ogni rotta via harness `OpenCodeWidgets detect`
- [ ] Aggiornare `HANDOFF_NEXT_AI.md`, `README.md`, `Docs/ARCHITETTURA_CORE.md`

### Fase 7 — L4/L5: iOS Simulator + iPhone (dipende da hardware)
- [ ] **L4 (opzionale):** LiveE2E su iOS Simulator (path UI contro server reale)
- [ ] **L5 (bloccato se device assente):** iPhone via USB, trust profilo,
  URL link-local `169.254.x.x`, verifica live UI

---

## 2. Metriche di completamento

| Metrica | Attuale | Target |
|---|---|---|
| Test unitari `swift test` | 421 | 394 + nuovi (F4/F6/F8) |
| Check LiveE2E vs server reale | 27/27 | 27/27 invariato (o più) |
| Rotte mock | ~40 (tutte v2 client) | tutte quelle del client v2 (~40) |
| Stress 3x | 3/3 | 3/3 (suite ampliata) |
| CI | assente | verde su push |
| Force-unwrap runtime | 0 | 0 |

## 3. Rischi

1. **Wire model v2 shell/command** non verificabile sul 1.18 (rotta v2 assente) —
   mitigazione: fallback v1 corretto, documentazione, test mock della v2.
2. **Turni LLM reali 2s→180s+** e testo vuoto (solo reasoning) — i check E2E non
   devono asserire il testo (lezione S22.6/7).
3. **Flaky per timing** — invarianti robusti, mai assert su timing esatti
   (lezione S20.7).
4. **CI senza server reale** — il LiveE2E in CI va contro il mock; il run contro
   il server reale resta manuale (dipende da `opencode serve` attivo).
5. **Rette mock con wire sbagliato** — ogni nuova rotta mock deve rispettare i
   fixture congelati, verificati con round-trip JSON (lezione S21.5).

## 4. Ordine di esecuzione consigliato

Igiene (Fase 1) → F4 (mock) → F7 (robustezza) → F6 (stress) → F8 (CI/view-model)
→ F9 (verifica finale + red team) → L4/L5 (hardware).

Ogni fase: implementazione → verifica (`swift build`+`swift test`) → commit.
Regola: mai due `swift build` in parallelo sullo stesso package.
