// The names this build carries. One place, so the window class, the registry
// key, the single-instance mutex and the data folder can never disagree.
#pragma once

#define APP_NAME L"Puzzle"
#define APP_DATA_FOLDER L"Puzzle"
#define APP_REGISTRY_KEY L"Software\\Puzzle"
#define APP_INSTANCE_MUTEX L"Local\\Puzzle.SingleInstance.4e81b9"
#define APP_IPC_CLASS L"Puzzle.IPC"
#define APP_WINDOW_CLASS L"Puzzle.Window"
#define APP_VERSION L"2.0"
#define APP_USER_MODEL_ID L"Example.Puzzle"
/// The environment variable a launch reads its project from (PUZZLE_OPEN).
#define APP_OPEN_VARIABLE L"PUZZLE_OPEN"
/// What the command-line launcher sets so the app knows who started it.
#define APP_LAUNCHER_VARIABLE L"PUZZLE_LAUNCHER"
