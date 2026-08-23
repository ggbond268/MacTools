# Feature — Dock Lock

Last verified: 2026-08-20

Status: implemented
Source of truth: yes

## Résumé

- Bloque le déplacement accidentel du Dock entre écrans.
- Uniquement lorsque le Dock est en bas et que le masquage automatique est désactivé.
- Le curseur reste utilisable horizontalement au bord inférieur.
- Les passages vers un écran placé en dessous restent accessibles.

## User flow

- L’utilisateur active « Dock Lock » dans le panneau principal.
- MacTools demande l’autorisation Accessibilité si elle manque.
- Le curseur est retenu quelques points avant les bords inférieurs exposés des écrans qui n’affichent pas le Dock.
- L’utilisateur désactive le commutateur pour restaurer le comportement macOS.
- L’utilisateur peut aussi ajouter les actions bascule, activation et désactivation à Action Grid ou à un workflow ; les actions déterministes prennent en charge les Run Links.

## Règles métier

| Règle | Markdown | Code centralisé | Consommation |
|---|---|---|---|
| Aucune règle métier durable | — | — | — |

## Décisions

| Date | Décision | Raison | Impact |
|---|---|---|---|
| 2026-08-10 | Portée minimale, sans sélection d’écran, raccourci ni démarrage automatique | Reproduire le comportement de verrouillage demandé sans extension produit | Tous les écrans sont protégés au bord inférieur après activation explicite |
| 2026-08-10 | Nom « Dock Lock » | Évite de reprendre la marque et l’identité visuelle de DockLock | Plugin `dock-lock` |
| 2026-08-12 | Actions canoniques partagées | La grille, les workflows et les Run Links doivent réutiliser la même mutation et les mêmes contrôles de permission | Une bascule avec état plus des actions déterministes activer/désactiver |

## Plan

- [x] P001 — Formaliser le contrat et la portée.
- [x] P002 — Implémenter le plugin et sa session CGEvent tap.
- [x] P003 — Ajouter les tests ciblés et la documentation ; vérifier les contrôles disponibles.
- [x] P004 — Créer la PR.
- [x] P005 — Expose the persisted enable control on the plugin settings page.

## TODO

- [x] F001 — Définir le comportement du curseur — files: `docs/features/dock-lock.md` — status: done
- [x] F002 — Créer le plugin — files: `Plugins/DockLock/` — status: done
- [x] F003 — Ajouter la documentation utilisateur et le fragment de changelog — files: `README.md`, `changes/unreleased/` — status: done
- [x] F004 — Publier les actions canoniques pour les surfaces partagées — files: `Plugins/DockLock/`, `docs/plugins/action-provider-coverage.md` — status: done
- [x] F005 — Add the settings toggle, targeted tests, and release note — files: `Plugins/DockLock/`, `docs/user-stories/plugins/dock-lock-settings-toggle.md`, `changes/unreleased/` — status: done

## Journal impl Codex

- 2026-08-10 — Contrat établi. La référence observée bloque le pointeur près du bord inférieur avec une autorisation Accessibilité. Aucun code ou actif de cette référence n’est repris.
- 2026-08-10 — Plugin créé. `Plugins/DockLock/Sources/DockLockPlugin.swift` installe un CGEvent tap et réactive le tap après désactivation système ; les tests couvrent le calcul de bord, l’activation, la désactivation et l’absence d’autorisation.
- 2026-08-10 — Revue spec : premier lancement désactivé ; la session vérifie périodiquement que le Dock reste en bas avant tout blocage. Ajout des tests correspondants.
- 2026-08-10 — Revue standards : la désactivation arrête désormais le CGEvent tap, y compris pendant une mise à jour ; test de cycle ajouté.
- 2026-08-10 — Revue sécurité : une orientation Dock inconnue ne bloque jamais le pointeur ; tests `nil` et valeur invalide ajoutés.
- 2026-08-10 — Checks : `git diff --check`, validation JSON, génération de configuration plugin et `swiftc -parse` réussis. Compilation XCTest bloquée : Xcode et xcodegen ne sont pas installés dans l’environnement.
- 2026-08-10 — PR créée : `ggbond268/MacTools#263`.
- 2026-08-10 — XCTest local : le cas d’autorisation manquante était initialisé désactivé, donc ne pouvait pas produire l’erreur attendue. Le test initialise désormais le plugin activé ; la vérification couvre bien le refus d’autorisation. Le mock de test conserve l’isolation MainActor du scénario.
- 2026-08-11 — Compatibilité Swift 6 : le polling du Dock utilise un `Timer` cible/sélecteur sur la boucle principale, sans closure `@Sendable` capturant le moniteur.
- 2026-08-12 — Revue sécurité : le tap utilise la session utilisateur ; seuls les bords extérieurs sans Dock sont retenus. Le mode échoue ouvert pour le masquage automatique, les écrans empilés et une géométrie Dock inconnue.
- 2026-08-20 — P005/F004 started. The settings page will reuse the existing primary-panel switch action, preserving storage, permission handling, monitor lifecycle, and state notifications.
- 2026-08-20 — P005/F004 complete. `Plugins/DockLock/Sources/DockLockPlugin.swift:327` defines the settings form and routes its toggle through the primary-panel action at `:384`; `Plugins/DockLock/Tests/DockLockPluginTests.swift:167` covers the rendered form, persistence, lifecycle, and missing permission. `swiftc -parse`, JSON validation, and `git diff --check` passed. The focused XCTest build is blocked by the unrelated missing `Sources/MacToolsPluginKit/TrackpadGestureCatalog.swift` input; the user-story validator is blocked only by the pre-existing `docs/user-stories/app/dock-icon-for-settings-window.md` format.

## Files actuels

| Zone | Files |
|---|---|
| Plugin similaire | `Plugins/MouseEnhancer/`, `Plugins/AutoHideDock/` |
| Documentation | `docs/plugins/local-native-plugins.md` |

## Files à créer/modifier

- `Plugins/DockLock/`
- `README.md`, `README.zh-CN.md`
- `changes/unreleased/dock-lock.md`
- `CONTRIBUTING.md`, `docs/plugins/local-native-plugins.md`

## Tests / QA

- [x] Couvrir le calcul de retenue du curseur, l’activation, la désactivation, la perte d’autorisation et les orientations non prises en charge.
- [x] Vérifier le manifeste et la génération de configuration plugin.
- [x] Compiler et exécuter les XCTest ciblés — Xcode 26.6 ; exécution locale sans signature.

## Historique

<!-- Ne lire que pour bug, régression, audit, ou demande explicite. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
| 2026-08-10 | `mus` | Feature | Dock Lock implémenté et PR #263 créée |
