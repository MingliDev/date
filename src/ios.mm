//
// The MIT License (MIT)
//
// Copyright (c) 2016 Alexander Kormanovsky
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

#include "date/ios.h"

#if TARGET_OS_IPHONE

#include <Foundation/Foundation.h>

#include <fstream>
#include <zlib.h>
#include <sys/stat.h>
#include <functional>

#ifndef TAR_DEBUG
#  define TAR_DEBUG 0
#endif

#define INTERNAL_DIR        "Library"
#define TZDATA_DIR          "tzdata"
#define TARGZ_EXTENSION     "tar.gz"

#define TAR_BLOCK_SIZE                  512
#define TAR_TYPE_POSITION               156
#define TAR_NAME_POSITION               0
#define TAR_NAME_SIZE                   100
#define TAR_SIZE_POSITION               124
#define TAR_SIZE_SIZE                   12

namespace date
{
    namespace iOSUtils
    {
        struct TarInfo
        {
            char type;
            std::string name;
            std::string content;
            long contentSize;
        };

        std::string convertCFStringRefPathToCStringPath(CFStringRef ref);
        bool extractTzdata(CFURLRef homeUrl, CFURLRef archiveUrl, std::string destPath);
        bool dxTarRead(const void* tarData,
                       const long tarSize,
                       std::function<void (const TarInfo &)> const &callback);
        bool writeFile(const std::string &tzdataPath, const TarInfo &tarInfo);

        std::string
        get_current_timezone()
        {
            CFTimeZoneRef tzRef = CFTimeZoneCopySystem();
            CFStringRef tzNameRef = CFTimeZoneGetName(tzRef);
            CFIndex bufferSize = CFStringGetLength(tzNameRef) + 1;
            char buffer[bufferSize];

            if (CFStringGetCString(tzNameRef, buffer, bufferSize, kCFStringEncodingUTF8))
            {
                CFRelease(tzRef);
                return std::string(buffer);
            }

            CFRelease(tzRef);

            return "";
        }

        std::string
        get_tzdata_path()
        {
            CFURLRef homeUrlRef = CFCopyHomeDirectoryURL();
            CFStringRef homePath = CFURLCopyPath(homeUrlRef);
            std::string path(std::string(convertCFStringRefPathToCStringPath(homePath)) +
                             INTERNAL_DIR + "/" + TZDATA_DIR);
            std::string result_path(std::string(convertCFStringRefPathToCStringPath(homePath)) +
                                    INTERNAL_DIR);

            if (access(path.c_str(), F_OK) == 0)
            {
#if TAR_DEBUG
                printf("tzdata dir exists\n");
#endif
                CFRelease(homeUrlRef);
                CFRelease(homePath);

                return result_path;
            }

            CFBundleRef mainBundle = CFBundleGetMainBundle();
            CFArrayRef paths = CFBundleCopyResourceURLsOfType(mainBundle, CFSTR(TARGZ_EXTENSION),
                                                              NULL);

            if (CFArrayGetCount(paths) != 0)
            {
                // get archive path, assume there is no other tar.gz in bundle
                CFURLRef archiveUrl = static_cast<CFURLRef>(CFArrayGetValueAtIndex(paths, 0));
                CFStringRef archiveName = CFURLCopyPath(archiveUrl);
                archiveUrl = CFBundleCopyResourceURL(mainBundle, archiveName, NULL, NULL);

                extractTzdata(homeUrlRef, archiveUrl, path);

                CFRelease(archiveUrl);
                CFRelease(archiveName);
            }

            CFRelease(homeUrlRef);
            CFRelease(homePath);
            CFRelease(paths);

            return result_path;
        }

        std::string
        convertCFStringRefPathToCStringPath(CFStringRef ref)
        {
            CFIndex bufferSize = CFStringGetMaximumSizeOfFileSystemRepresentation(ref);
            char *buffer = new char[bufferSize];
            CFStringGetFileSystemRepresentation(ref, buffer, bufferSize);
            auto result = std::string(buffer);
            delete[] buffer;
            return result;
        }

        bool
        extractTzdata(CFURLRef homeUrl, CFURLRef archiveUrl, std::string destPath)
        {
            std::string TAR_TMP_PATH = "/tmp.tar";

            CFStringRef homeStringRef = CFURLCopyPath(homeUrl);
            auto homePath = convertCFStringRefPathToCStringPath(homeStringRef);
            CFRelease(homeStringRef);

            CFStringRef archiveStringRef = CFURLCopyPath(archiveUrl);
            auto archivePath = convertCFStringRefPathToCStringPath(archiveStringRef);
            CFRelease(archiveStringRef);

            // create Library path
            auto libraryPath = homePath + INTERNAL_DIR;

            // create tzdata path
            auto tzdataPath = libraryPath + "/" + TZDATA_DIR;

            // -- replace %20 with " "
            const std::string search = "%20";
            const std::string replacement = " ";
            size_t pos = 0;

            while ((pos = archivePath.find(search, pos)) != std::string::npos) {
                archivePath.replace(pos, search.length(), replacement);
                pos += replacement.length();
            }

            gzFile tarFile = gzopen(archivePath.c_str(), "rb");

            // create tar unpacking path
            auto tarPath = libraryPath + TAR_TMP_PATH;

            // create tzdata directory
            mkdir(destPath.c_str(), S_IRWXU | S_IRWXG | S_IROTH | S_IXOTH);

            // ======= extract tar ========

            std::ofstream os(tarPath.c_str(), std::ofstream::out | std::ofstream::app);
            unsigned int bufferLength = 1024 * 256;  // 256Kb
            unsigned char *buffer = (unsigned char *)malloc(bufferLength);
            bool success = true;

            while (true)
            {
                int readBytes = gzread(tarFile, buffer, bufferLength);

                if (readBytes > 0)
                {
                    os.write((char *) &buffer[0], readBytes);
                }
                else
                    if (readBytes == 0)
                    {
                        break;
                    }
                    else
                        if (readBytes == -1)
                        {
                            printf("decompression failed\n");
                            success = false;
                            break;
                        }
                        else
                        {
                            printf("unexpected zlib state\n");
                            success = false;
                            break;
                        }
            }

            os.close();
            free(buffer);
            gzclose(tarFile);

            if (!success)
            {
                remove(tarPath.c_str());
                return false;
            }

            // ======== extract files =========

            // get file size
            struct stat stat_buf;
            int res = stat(tarPath.c_str(), &stat_buf);
            
            if (res != 0)
            {
                printf("error file size\n");
                remove(tarPath.c_str());
                return false;
            }
            
            auto tarSize = stat_buf.st_size;
            
            std::ifstream is(tarPath.c_str(), std::ifstream::in | std::ifstream::binary);
            std::string tarBuffer((std::istreambuf_iterator<char>(is)), std::istreambuf_iterator<char>());
#if TAR_DEBUG
            int count = 0;
            
            printf("Extracting and writing tzdata files:\n");
#endif
            dxTarRead(tarBuffer.c_str(), tarSize, [&](const TarInfo &tarInfo) {
#if TAR_DEBUG
                printf("%d '%s' %ld bytes\n", ++count, tarInfo.name.c_str(), tarInfo.contentSize);
#endif
                switch (tarInfo.type) {
                    case '0':   // file
                    case '\0':  //
                    {
                        writeFile(tzdataPath, tarInfo);
                        break;
                    }
                }
            });

            remove(tarPath.c_str());

            return true;
        }
        
        /**
         Based on https://github.com/DeXP/dxTarRead/blob/f5c9654137db609d8a584dfa75c652f4c9843f21/dxTarRead.c#L12
         See also https://habr.com/ru/articles/320834/
         */
        bool dxTarRead(const void* tarData, const long tarSize,
                       std::function<void (const TarInfo &)> const &callback)
        {
            const int NAME_OFFSET = 0, SIZE_OFFSET = 124, MAGIC_OFFSET = 257, TYPE_OFFSET = 124;
            const int BLOCK_SIZE = 512, SZ_SIZE = 12, MAGIC_SIZE = 5;
            const char MAGIC[] = "ustar"; /* Modern GNU tar's magic const */
            const char* tar = (const char*) tarData; /* From "void*" to "char*" */
            long size, mul, i, p = 0, newOffset = 0;

            do { /* "Load" data from tar - just point to passed memory*/
                const char* name = tar + NAME_OFFSET + p + newOffset;
                const char* sz = tar + SIZE_OFFSET + p + newOffset; /* size string */
                const char type = (tar + TYPE_OFFSET + p + newOffset)[0];
                
                p += newOffset; /* pointer to current file's data in TAR */

                for(i=0; i<MAGIC_SIZE; i++) /* Check for supported TAR version */
                    if( tar[i + MAGIC_OFFSET + p] != MAGIC[i] ) return false; /* = NULL */

                size = 0; /* Convert file size from string into integer */
                for(i=SZ_SIZE-2, mul=1; i>=0; mul*=8, i--) /* Octal str to int */
                    if( (sz[i]>='0') && (sz[i] <= '9') ) size += (sz[i] - '0') * mul;

                /* Offset size in bytes. Depends on file size and TAR's block size */
                newOffset = (1 + size/BLOCK_SIZE) * BLOCK_SIZE; /* trim by block */
                if( (size % BLOCK_SIZE) > 0 ) newOffset += BLOCK_SIZE;
                
                auto content = tar + p + BLOCK_SIZE;
                TarInfo tarInfo = {type, name, content, size};
                
                callback(tarInfo);
            } while(p + newOffset + BLOCK_SIZE <= tarSize);
            
            return true;
        }
        
        bool
        writeFile(const std::string &tzdataPath, const TarInfo &tarInfo)
        {
            std::ofstream os(tzdataPath + "/" + tarInfo.name, std::ofstream::out | std::ofstream::binary);

            if (!os) {
                return false;
            }

            os.write(tarInfo.content.c_str(), tarInfo.contentSize);
            os.close();

            return true;
        }

    }  // namespace iOSUtils
}  // namespace date

#endif  // TARGET_OS_IPHONE
