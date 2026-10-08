// Records why the process went down. A crash report says where, not what;
// this keeps the exception code, the faulting module and the stack in
// %LOCALAPPDATA%\Puzzle\Logs\exceptions.log (ExceptionLog.swift).
#pragma once

namespace ExceptionLog {
void install();
}
