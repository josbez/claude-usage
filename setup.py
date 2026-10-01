from setuptools import setup

APP = ['app.py']
DATA_FILES = [('', ['core.py', 'fetch_limits.py', 'dev/dashboard.html'])]

OPTIONS = {
    'argv_emulation': False,
    'iconfile': 'icon/ClaudeUsage.icns',
    'plist': {
        'CFBundleName': 'ClaudeUsage',
        'CFBundleDisplayName': 'Claude Usage',
        'CFBundleIdentifier': 'com.jos.claude-usage',
        'CFBundleVersion': '1.2.5',
        'CFBundleShortVersionString': '1.2.5',
        'LSUIElement': True,          # Geen dock-icon
        'NSHighResolutionCapable': True,
    },
    'packages': ['Crypto'],
    'includes': [
        'Foundation', 'AppKit', 'WebKit',
        'objc', 'hashlib', 'sqlite3',
        'core', 'updater', 'UserNotifications', 'PyObjCTools',
    ],
    'excludes': ['tkinter', 'rumps'],
}

setup(
    app=APP,
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
    setup_requires=['py2app'],
)
