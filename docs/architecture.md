# Architecture Parrot

## Contrat produit actif

Parrot est une dictée macOS locale en français, déclenchée par `Fn`. La priorité
absolue est que la dictée simple, le double `Fn` verrouillé, le mute/restauration
audio et l'injection au curseur restent fiables.

- Transcription : `canary-1b-v2-mlx-bf16` uniquement.
- Langue : `source_lang="fr"`, `target_lang="fr"`.
- Réseau : aucun audio ni texte envoyé à un service distant.
- Post-traitement : dictionnaire local déterministe et structure de liste
  uniquement lorsqu'elle est explicitement dictée (`petit 1`, `petit 2`, …).
- Aucune couche générative ne réécrit une dictée libre en e-mail, réponse ou
  document.

Les anciennes sources WhisperKit et vidéo/SRT restent présentes comme matériel
de rollback, mais `Package.swift` les exclut de la cible et des tests actifs.

## Flux actif

```text
Fn / CGEventTap
      │
      ▼
FnDictationGesture ──► AudioCapture (16 kHz mono Float32)
      │                         │
      │                         ▼
      │                  WAV temporaire
      │                         │
      ▼                         ▼
RecordingOverlay ◄── CanaryMLXTranscriber ──► CanaryWorker.py / MLX
      │                         │
      ▼                         ▼
  waveform / spinner      LocalDictionary
                                      │
                                      ▼
                           DictationFormatter
                                      │
                                      ▼
                                TextInjector
```

## Moteur Canary MLX

`CanaryMLXTranscriber` est un actor Swift qui sérialise les demandes. Il écrit
les échantillons de la dictée en WAV temporaire et parle par JSON ligne à ligne
à `CanaryWorker.py`. Le worker Python MLX reste enfant du processus Parrot et
charge le modèle une seule fois ; il ne loggue les diagnostics que sur stderr.

Le runtime et ses poids résident dans
`~/Library/Application Support/parrot/canary-mlx`. Les captures supérieures à
30 secondes sont découpées avant génération afin de borner les décodages
gloutons de cette conversion MLX.

## Dictée et UI

`HotkeyMonitor` observe la touche Fn. `FnDictationGestureController` distingue
le maintien standard, le double appui qui verrouille, et l'appui suivant qui
arrête. `OutputMuteController` sauvegarde puis restaure l'état de la sortie
audio système autour de toute capture.

`RecordingOverlay` est un `NSPanel` AppKit click-through qui héberge une vue
SwiftUI : waveform à l'écoute, cadenas quand la dictée est verrouillée, capsule
noire et spinner blanc pendant la transcription.

`TextInjector` utilise le presse-papiers et le collage synthétique plutôt que
l'injection caractère par caractère ; cela conserve correctement les retours à
la ligne dans les éditeurs riches.

## Déploiement local

L'installation locale utilise le bundle signé :

```text
/Users/ecologni/Applications/Parrot.app
```

Son `LaunchAgent` lance `parrot run --skip-doctor`. Le bundle, le chemin et la
signature doivent rester stables afin de préserver l'autorisation
Accessibilité/TCC. Toute réinstallation doit donc reconstruire, signer, vérifier
et remplacer ce bundle précisément, sans modifier les permissions.

## Validation active

Les tests actifs couvrent la machine d'état Fn, la dictée fidèle et les listes
explicitement annoncées, le dictionnaire, l'injection par presse-papiers, le
menu et la configuration Canary. Les anciens tests vidéo/Whisper sont exclus
avec les sources correspondantes et ne constituent pas une preuve de la cible
active.
