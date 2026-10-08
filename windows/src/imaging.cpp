#include "imaging.h"

#include <d2d1_3.h>
#include <shlwapi.h>

namespace Imaging {

IWICImagingFactory* factory() {
    static Com<IWICImagingFactory> made;
    if (!made) {
        CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_IWICImagingFactory,
                         reinterpret_cast<void**>(made.put()));
    }
    return made.get();
}

namespace {

Com<IWICBitmapFrameDecode> firstFrame(IStream* stream) {
    Com<IWICBitmapDecoder> decoder;
    if (!factory() || FAILED(factory()->CreateDecoderFromStream(stream, nullptr, WICDecodeMetadataCacheOnDemand,
                                                                decoder.put()))) {
        return {};
    }
    Com<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, frame.put()))) return {};
    return frame;
}

/// EXIF orientation 1…8; 1 when there is none.
int orientation(IWICBitmapFrameDecode* frame) {
    Com<IWICMetadataQueryReader> reader;
    if (FAILED(frame->GetMetadataQueryReader(reader.put())) || !reader) return 1;
    PROPVARIANT value;
    PropVariantInit(&value);
    int result = 1;
    if (SUCCEEDED(reader->GetMetadataByName(L"System.Photo.Orientation", &value))) {
        if (value.vt == VT_UI2) result = value.uiVal;
    }
    PropVariantClear(&value);
    return result >= 1 && result <= 8 ? result : 1;
}

WICBitmapTransformOptions transformFor(int orientation) {
    switch (orientation) {
    case 2: return WICBitmapTransformFlipHorizontal;
    case 3: return WICBitmapTransformRotate180;
    case 4: return WICBitmapTransformFlipVertical;
    case 5: return (WICBitmapTransformOptions)(WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal);
    case 6: return WICBitmapTransformRotate90;
    case 7: return (WICBitmapTransformOptions)(WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal);
    case 8: return WICBitmapTransformRotate270;
    default: return WICBitmapTransformRotate0;
    }
}

Com<IStream> memoryStream(const std::string& data) {
    return Com<IStream>(SHCreateMemStream(reinterpret_cast<const BYTE*>(data.data()), (UINT)data.size()));
}

Com<IWICBitmapSource> decodeStream(IStream* stream, UINT maximum) {
    auto frame = firstFrame(stream);
    if (!frame) return {};
    UINT w = 0, h = 0;
    if (FAILED(frame->GetSize(&w, &h)) || w == 0 || h == 0) return {};
    Com<IWICBitmapSource> source = frame.as<IWICBitmapSource>();
    double scale = std::min(1.0, (double)std::max<UINT>(1, maximum) / std::max(w, h));
    if (scale < 1.0) {
        Com<IWICBitmapScaler> scaler;
        if (SUCCEEDED(factory()->CreateBitmapScaler(scaler.put()))
            && SUCCEEDED(scaler->Initialize(source.get(), std::max<UINT>(1, (UINT)(w * scale)),
                                            std::max<UINT>(1, (UINT)(h * scale)),
                                            WICBitmapInterpolationModeFant))) {
            source = scaler.as<IWICBitmapSource>();
        }
    }
    int o = orientation(frame.get());
    if (o != 1) {
        Com<IWICBitmapFlipRotator> rotator;
        if (SUCCEEDED(factory()->CreateBitmapFlipRotator(rotator.put()))
            && SUCCEEDED(rotator->Initialize(source.get(), transformFor(o)))) {
            source = rotator.as<IWICBitmapSource>();
        }
    }
    Com<IWICFormatConverter> converter;
    if (FAILED(factory()->CreateFormatConverter(converter.put()))
        || FAILED(converter->Initialize(source.get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone,
                                        nullptr, 0, WICBitmapPaletteTypeCustom))) {
        return {};
    }
    // Decoded once into memory, so drawing never goes back to the file.
    Com<IWICBitmap> bitmap;
    if (FAILED(factory()->CreateBitmapFromSource(converter.get(), WICBitmapCacheOnLoad, bitmap.put()))) {
        return {};
    }
    return bitmap.as<IWICBitmapSource>();
}

}  // namespace

std::optional<Info> probe(const std::string& data) {
    auto stream = memoryStream(data);
    if (!stream) return std::nullopt;
    auto frame = firstFrame(stream.get());
    if (!frame) return std::nullopt;
    UINT w = 0, h = 0;
    if (FAILED(frame->GetSize(&w, &h)) || w == 0 || h == 0) return std::nullopt;
    // A header that parses but pixels that do not are not a picture.
    stream = memoryStream(data);
    if (!decodeStream(stream.get(), 1)) return std::nullopt;
    stream = memoryStream(data);
    auto again = firstFrame(stream.get());
    int o = again ? orientation(again.get()) : 1;
    Info info;
    bool swapped = o >= 5 && o <= 8;
    info.width = (float)(swapped ? h : w);
    info.height = (float)(swapped ? w : h);
    return info;
}

Com<IWICBitmapSource> decode(const std::string& data, UINT maximum) {
    auto stream = memoryStream(data);
    if (!stream) return {};
    return decodeStream(stream.get(), maximum);
}

Com<IWICBitmapSource> decodeFile(const std::wstring& path, UINT maximum) {
    Com<IStream> stream;
    if (FAILED(SHCreateStreamOnFileEx(path.c_str(), STGM_READ | STGM_SHARE_DENY_NONE, FILE_ATTRIBUTE_NORMAL,
                                      FALSE, nullptr, stream.put()))) {
        return {};
    }
    return decodeStream(stream.get(), maximum);
}

Com<ID2D1Bitmap> bitmap(ID2D1RenderTarget* target, IWICBitmapSource* source) {
    Com<ID2D1Bitmap> out;
    if (target && source) target->CreateBitmapFromWicBitmap(source, nullptr, out.put());
    return out;
}

namespace {
float attributeNumber(const std::string& tag, const char* name) {
    std::string key = std::string(" ") + name + "=\"";
    size_t at = tag.find(key);
    if (at == std::string::npos) return 0;
    size_t start = at + key.size();
    try {
        return std::stof(tag.substr(start));
    } catch (...) {
        return 0;
    }
}
}  // namespace

std::optional<Size> svgSize(const std::string& svg) {
    size_t open = svg.find("<svg");
    if (open == std::string::npos) return std::nullopt;
    size_t close = svg.find('>', open);
    if (close == std::string::npos) return std::nullopt;
    std::string tag = svg.substr(open, close - open);
    float w = attributeNumber(tag, "width"), h = attributeNumber(tag, "height");
    if (w > 0 && h > 0) return Size(w, h);
    size_t box = tag.find("viewBox=\"");
    if (box != std::string::npos) {
        float x = 0, y = 0, bw = 0, bh = 0;
        std::string values = replaceAll(tag.substr(box + 9), ",", " ");
        if (sscanf(values.c_str(), "%f %f %f %f", &x, &y, &bw, &bh) == 4 && bw > 0 && bh > 0) {
            return Size(bw, bh);
        }
    }
    return Size(300, 150);
}

Com<ID2D1Bitmap1> renderSVG(const std::string& svg, UINT width, UINT height) {
    if (svg.empty() || width == 0 || height == 0) return {};
    ID2D1DeviceContext* scratch = Render::scratchContext();
    if (!scratch) return {};
    Com<ID2D1DeviceContext5> context;
    scratch->QueryInterface(__uuidof(ID2D1DeviceContext5), reinterpret_cast<void**>(context.put()));
    if (!context) return {};
    auto stream = memoryStream(svg);
    if (!stream) return {};
    Com<ID2D1SvgDocument> document;
    if (FAILED(context->CreateSvgDocument(stream.get(), D2D1::SizeF((float)width, (float)height), document.put()))
        || !document) {
        return {};
    }
    Com<ID2D1SvgElement> root;
    document->GetRoot(root.put());
    if (!root) return {};
    // The viewport given to Direct2D decides the size; the viewBox scales into it.
    if (!root->IsAttributeSpecified(L"viewBox")) {
        auto natural = svgSize(svg);
        if (natural) {
            D2D1_SVG_VIEWBOX box{0, 0, natural->w, natural->h};
            root->SetAttributeValue(L"viewBox", D2D1_SVG_ATTRIBUTE_POD_TYPE_VIEWBOX, &box, sizeof box);
        }
    }
    root->SetAttributeValue(L"width", (float)width);
    root->SetAttributeValue(L"height", (float)height);
    Com<ID2D1Bitmap1> bitmap;
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        96, 96);
    if (FAILED(context->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, &props, bitmap.put()))) return {};
    context->SetTarget(bitmap.get());
    context->SetDpi(96, 96);
    context->BeginDraw();
    context->SetTransform(D2D1::Matrix3x2F::Identity());
    context->Clear(D2D1::ColorF(0, 0, 0, 0));
    context->DrawSvgDocument(document.get());
    HRESULT hr = context->EndDraw();
    context->SetTarget(nullptr);
    if (FAILED(hr)) return {};
    return bitmap;
}

}  // namespace Imaging
