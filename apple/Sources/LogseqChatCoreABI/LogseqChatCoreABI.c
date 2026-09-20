#include "LogseqChatCoreABI.h"

#include <stdio.h>
#include <zlib.h>

int32_t logseq_chat_gunzip_file(const char *input_path, const char *output_path) {
    FILE *input = fopen(input_path, "rb");
    if (input == NULL) {
        return Z_ERRNO;
    }

    FILE *output = fopen(output_path, "wb");
    if (output == NULL) {
        fclose(input);
        return Z_ERRNO;
    }

    z_stream stream = {0};
    int result = inflateInit2(&stream, 15 + 16);
    if (result != Z_OK) {
        fclose(output);
        fclose(input);
        remove(output_path);
        return result;
    }

    unsigned char input_buffer[64 * 1024];
    unsigned char output_buffer[64 * 1024];
    do {
        stream.avail_in = (uInt)fread(input_buffer, 1, sizeof(input_buffer), input);
        if (ferror(input)) {
            result = Z_ERRNO;
            break;
        }
        if (stream.avail_in == 0) {
            break;
        }
        stream.next_in = input_buffer;

        do {
            stream.avail_out = sizeof(output_buffer);
            stream.next_out = output_buffer;
            result = inflate(&stream, Z_NO_FLUSH);
            if (result == Z_NEED_DICT) {
                result = Z_DATA_ERROR;
            }
            if (result == Z_DATA_ERROR || result == Z_MEM_ERROR) {
                break;
            }

            size_t produced = sizeof(output_buffer) - stream.avail_out;
            if (produced > 0 && fwrite(output_buffer, 1, produced, output) != produced) {
                result = Z_ERRNO;
                break;
            }
        } while (stream.avail_out == 0);
    } while (result != Z_STREAM_END);

    if (result != Z_STREAM_END && result != Z_ERRNO && result != Z_DATA_ERROR && result != Z_MEM_ERROR) {
        result = Z_DATA_ERROR;
    }

    inflateEnd(&stream);
    fclose(output);
    fclose(input);

    if (result != Z_STREAM_END) {
        remove(output_path);
        return result;
    }
    return Z_OK;
}
