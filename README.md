# TextNow machine

A single purpose machine that runs in GitHub Actions: Chrome on a
virtual screen, opened straight into TextNow as a standalone app
window, reached through a streaming link. It carries the golden
browser build's disguise and home exit-node routing, and its Chrome
profile is saved encrypted into this repo every minute and restored
at every start, so the TextNow login made here once is the login
every session wakes up with.

The door is index.html, served by GitHub Pages at
https://iamnottaiiii.github.io/textnow-machine/ . The door holds no
address of its own. On every visit it reads live.json fresh,
forwards you to the current session when the machine is awake, and
shows the last known address when the machine is between sessions.
