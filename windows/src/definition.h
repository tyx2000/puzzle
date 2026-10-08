// Ctrl+click navigation: file references first, then the nearest
// declaration in the file, then the project's source files
// (DefinitionNavigator.swift). Offsets are UTF-8 bytes.
#pragma once

#include "textrange.h"
#include "base.h"

#include <string_view>

namespace DefinitionNavigator {

struct Destination {
    std::wstring path;
    size_t location = 0;
};

std::optional<Destination> resolve(std::string_view text, const std::wstring& sourcePath,
                                   const std::wstring& projectRoot, size_t location);
bool hasNavigableToken(std::string_view text, size_t location);
/// The range painted while Ctrl is held over it.
std::optional<TextRange> targetRange(std::string_view text, size_t location);

}  // namespace DefinitionNavigator
