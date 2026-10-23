// Local string storage for inert CEF fixtures. The real dylib's string entry points are unavailable
// before cef_load_library; no fixture should need a Chromium runtime just to construct an argument.
#pragma once
#define cef_string_utf16_clear FixtureClear16
#define cef_string_utf8_clear FixtureClear8
#define cef_string_utf16_set FixtureSet16
#define cef_string_utf16_cmp FixtureCompare16
#define cef_string_utf8_to_utf16 FixtureFrom8
#define cef_string_utf16_to_utf8 FixtureTo8
#import <Foundation/Foundation.h>
#include "include/internal/cef_string.h"
#include <string>

void FixtureClear16(cef_string_utf16_t *value) {
  if (value->dtor) value->dtor(value->str);
  *value = {};
}
void FixtureClear8(cef_string_utf8_t *value) {
  if (value->dtor) value->dtor(value->str);
  *value = {};
}
int FixtureSet16(const char16_t *source, size_t count, cef_string_utf16_t *out, int copy) {
  FixtureClear16(out);
  out->length = count;
  if (copy) {
    out->str = static_cast<char16_t *>(calloc(count + 1, sizeof(char16_t)));
    if (count) memcpy(out->str, source, count * sizeof(char16_t));
    out->dtor = [](char16_t *value) { free(value); };
  } else {
    out->str = const_cast<char16_t *>(source);
  }
  return 1;
}
int FixtureCompare16(const cef_string_utf16_t *a, const cef_string_utf16_t *b) {
  return std::u16string(a->str ?: u"", a->length).compare(std::u16string(b->str ?: u"", b->length));
}
int FixtureFrom8(const char *source, size_t count, cef_string_utf16_t *out) {
  NSString *text = [[NSString alloc] initWithBytes:source length:count encoding:NSUTF8StringEncoding];
  if (!text) return 0;
  FixtureClear16(out);
  out->length = text.length;
  out->str = static_cast<char16_t *>(calloc(out->length + 1, sizeof(char16_t)));
  out->dtor = [](char16_t *value) { free(value); };
  [text getCharacters:reinterpret_cast<unichar *>(out->str) range:NSMakeRange(0, text.length)];
  return 1;
}
int FixtureTo8(const char16_t *source, size_t count, cef_string_utf8_t *out) {
  NSString *text = [[NSString alloc] initWithCharacters:reinterpret_cast<const unichar *>(source) length:count];
  NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (!bytes) return 0;
  FixtureClear8(out);
  out->length = bytes.length;
  out->str = static_cast<char *>(calloc(out->length + 1, 1));
  if (out->length) memcpy(out->str, bytes.bytes, out->length);
  out->dtor = [](char *value) { free(value); };
  return 1;
}
