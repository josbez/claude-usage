from setuptools import setup

APP = ['app.py']
DATA_FILES = [('', ['core.py', 'fetch_limits.py', 'dashboard.html'])]

OPTIONS = {
    'argv_emulation': False,
    'plist': {
        'CFBundleName': 'ClaudeUsage',
        'CFBundleDisplayName': 'Claude Usage',
        'CFBundleIdentifier': 'com.jos.claude-usage',
        'CFBundleVersion': '1.0',
        'CFBundleShortVersionString': '1.0',
        'LSUIElement': True,          # Geen dock-icon
        'NSHighResolutionCapable': True,
    },
    'packages': ['Crypto'],
    'includes': [
        'Foundation', 'AppKit', 'WebKit',
        'objc', 'hashlib', 'sqlite3',
        'core',
    ],
    'excludes': ['tkinter', 'rumps'],
}

setup(
    app=APP,
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
    setup_requires=['py2app'],
)
