# Parrot

Parrot est une dictée macOS locale : maintenir `Fn`, parler, relâcher ; le
texte est inséré au curseur. Le produit actif cible Apple Silicon et utilise
**Canary 1B v2 MLX** en français, sans transcription cloud.

## Usage

1. Placez le curseur dans le champ de texte voulu.
2. Maintenez `Fn`, dictez, puis relâchez.
3. Pour verrouiller la dictée mains libres, faites un double appui sur `Fn`,
   puis un dernier appui pour arrêter.

Pendant l'enregistrement, Parrot mute temporairement la sortie audio active et
la restaure à l'arrêt, à l'erreur ou à la fermeture. La bulle waveform indique
l'écoute ; après le relâchement elle devient noire avec un spinner pendant la
transcription, puis disparaît lorsque le texte est injecté.

## Dictée fidèle

Parrot privilégie la fidélité : Canary fournit le texte, puis le dictionnaire
local applique des corrections déterministes. Il ne rédige pas de réponse,
message, e-mail, titre ou paragraphe à partir de ce que vous venez de dicter.

Une seule exception de présentation existe : une liste explicitement dictée et
séquentielle, par exemple `petit 1`, `petit 2`, `petit 3`, est rendue comme une
vraie liste numérotée. Une référence ordinaire telle que « point 12 puis point
15 » reste du texte normal.

## Dictionnaire local

Le dictionnaire est stocké dans `~/.config/parrot/dictionary.json`. Il est
rechargé à chaque dictée et ne quitte jamais le Mac. Il corrige notamment les
orthographes métier telles que FacilAbo, Codex, ChatGPT et TARS.

Ajoutez une correction depuis le menu waveform avec **Add dictionary
correction…**, ou modifiez directement le JSON.

## Modèle et runtime

Le seul modèle actif est `canary-1b-v2-mlx-bf16`, conversion MLX locale de
Canary 1B v2. Le runtime persistant se situe dans :

```text
~/Library/Application Support/parrot/canary-mlx
```

Le worker MLX charge le modèle une fois, puis reçoit les captures WAV temporaires
à transcrire. Il force `source_lang="fr"`, `target_lang="fr"` et active la
ponctuation/capitalisation native. Les captures longues sont découpées en
fenêtres de 30 secondes afin d'éviter les boucles de décodage connues du runtime
MLX actuel.

Whisper, le sous-titrage SRT et le rendu vidéo sont conservés dans le dépôt comme
matériel de retour arrière, mais ils ne font pas partie de la cible compilée ni
du menu actuel.

## CLI

```sh
parrot                         # lance le daemon au premier plan
parrot run --skip-doctor       # même lancement, permissions déjà vérifiées
parrot doctor                  # vérifie Microphone, Accessibilité et Fn
parrot models list             # affiche Canary et la présence du runtime local
parrot setup                   # aide à configurer les permissions Fn
```

## Développement

```sh
swift test
swift build -c release
```

Le bundle local signé utilisé sur cette machine est une installation privée ;
son chemin stable et sa signature sont importants pour la persistance TCC. Les
artefacts de rollback restent dans `.artifacts/` et sont volontairement ignorés
par Git.

Voir [l'architecture](docs/architecture.md) pour le flux de bout en bout.
