// Pictures: WIC for raster formats (ImageIO's role), Direct2D's SVG renderer
// for vector ones (PreviewImageSource.swift and the SVG preview's renderer).
#pragma once

#include "render.h"

#include <wincodec.h>

namespace Imaging {

IWICImagingFactory* factory();

/// What a document keeps of a picture: its size, upright.
struct Info {
    float width = 0;
    float height = 0;
};
/// Nullopt when the bytes are not a picture this machine can decode.
std::optional<Info> probe(const std::string& data);

/// Decoded upright, scaled so the longer side is at most `maximum` pixels,
/// as 32bpp premultiplied BGRA.
Com<IWICBitmapSource> decode(const std::string& data, UINT maximum);
Com<IWICBitmapSource> decodeFile(const std::wstring& path, UINT maximum);
/// A frame for one render target.
Com<ID2D1Bitmap> bitmap(ID2D1RenderTarget* target, IWICBitmapSource* source);

/// The size an SVG asks for (its width/height, or its viewBox); nullopt when
/// Direct2D cannot read it.
std::optional<Size> svgSize(const std::string& svg);
/// The SVG drawn at `size` pixels into a bitmap usable on the shared device.
Com<ID2D1Bitmap1> renderSVG(const std::string& svg, UINT width, UINT height);

}  // namespace Imaging
