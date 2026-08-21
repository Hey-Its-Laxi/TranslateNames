# TranslateNames

Batch translate folder and file names into any language using Google Translate. A simple Windows utility with a GUI for renaming files and directories with automatic language detection.
Built with Claude and Gemini.

<img width="1202" height="1398" alt="Screenshot 2026-08-21 132828" src="https://github.com/user-attachments/assets/0c0ce387-e393-47d7-8d8e-c71552a62ac6" />

## ✨ Features

- 🌍 **Translate Multiple Languages Together** — Arabic, Chinese, Dutch, English, Russian, Spanish, and more
- 👁️ **Live Preview** — See all proposed renames before applying them
- ✏️ **Edit & Customize** — Double-click any item to manually adjust the translated name
- ↩️ **Undo Support** — Easily revert the last batch of renames
- 🎨 **Dark Mode Support** — Automatically adapts to your Windows theme
- 📋 **CSV Logging** — Generates a log of all renames for your records
- 🚫 **Smart Filtering** — Skip files by extension or exclude items by regex pattern
- 🔄 **Conflict Resolution** — Automatically appends `(1)`, `(2)`, etc. if names already exist
- ⚙️ **Configuration** — Adjust translation delay, language detection, and more
- 🎯 **Batch Processing** — Handle hundreds of files at once

## 📋 Requirements

- **Windows 10** or later
- **Internet connection** (uses Google Translate API)

## 🚀 Installation

1. Download both Translate.vbs & TranslateNamesApp.ps1
2. Place both files in the same folder
3. Double-click `Translate.vbs` to launch the application

**No installation required**

## 📖 How to Use

### Basic Workflow

1. **Select a Folder**
   - Click **Browse...** to select a folder, or
   - Drag & drop a folder onto the window

2. **Configure Options**
   - Choose **Source language** (Auto-Detect or specific language)
   - Choose **Target language** (e.g., English, Spanish, French)
   - Check/uncheck:
     - **Include files** — translate file names
     - **Include folders** — translate folder names
     - **Include subfolders** — recursively process subdirectories
     - **Hide unchanged** — hide items that won't be renamed
     - **Write CSV log** — save a log file with all changes

3. **Preview Translations**
   - Click **Preview translations** to scan and translate names
   - Review the list and check the proposed new names
   - Optionally edit names by double-clicking them

4. **Apply Renames**
   - Click **Apply renames** to execute all changes
   - A log file (`translate-names-log.csv`) is saved in the target folder (if enabled)

5. **Undo (if needed)**
   - Click **Undo last apply** to revert all renames from the previous batch

### Advanced Options

| Option | Description | Default |
|--------|-------------|---------|
| **Source language** | Language to translate from (or Auto-Detect) | Auto-Detect |
| **Target language** | Language to translate to | English |
| **Regex** | Exclude items matching this regex pattern | *(empty)* |
| **Skip exts** | Comma-separated file extensions to skip (e.g., `.tmp, .log`) | *(empty)* |
| **Delay** | Milliseconds to wait between translations (reduces rate limiting) | 200ms |

## 🎨 Customization

The app automatically detects and applies your Windows theme (light or dark mode).

## ⚠️ Important Notes

- **Language Detection**: When "Auto-Detect" is selected as the source language, the app attempts to detect the language of each file/folder name. If it can't detect it with confidence, it won't rename the item.
- **Internet Required**: The app uses Google's free translation API, so an active internet connection is required.
- **Rate Limiting**: Translating thousands of items may trigger Google's rate limits. Use the "Delay" setting to slow down requests (default 200ms is usually safe).
- **No Backup**: While the app supports Undo, always test on a small batch first or ensure you have backups.

## 🐛 Troubleshooting

### "Invalid regular expression pattern"
- The regex pattern you entered has syntax errors. Test your pattern [here](https://regex101.com/).

### Translations timeout or fail
- Increase the **Delay** value (200ms → 500ms or higher)
- Check your internet connection
- Google may be rate-limiting; wait a few minutes and try again

### PowerShell execution policy error
- The launcher script automatically bypasses execution policy for this app. If you get a security prompt, click **Run** or **Yes**.

### Dark mode not applied
- The app queries Windows Registry. Ensure you have registry read permissions.
- Restart the app if you recently switched themes.

## 📝 CSV Log Format

Each rename is logged to `translate-names-log.csv` with these columns:

```
OriginalPath,NewName,Type,Status
C:\MyFolder\File.txt,Archivo.txt,File,Renamed
C:\MyFolder\Fotos,Fotos,Folder,Renamed
```

## 🔧 Technical Details

- **Language**: PowerShell (Windows-native, no installation needed)
- **Launcher**: VBScript wrapper for seamless integration
- **Translation API**: Google Translate (free, public endpoint)
- **Caching**: Translations are cached to speed up processing and reduce API calls
- **File Safety**: Uses `Rename-Item` with conflict detection; won't overwrite existing files

## 📄 License

This project is licensed under the **MIT License** — see [LICENSE](LICENSE) for details.

## 🤝 Contributing

Found a bug? Have a feature request? Feel free to open an issue or submit a pull request!

## 📞 Support

For issues, questions, or suggestions, please visit the [Issues](../../issues) page.
