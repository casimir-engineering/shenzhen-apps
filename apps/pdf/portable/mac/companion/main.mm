#import "SPDFMacCollectionCompanion.h"
#include <string.h>

// Private pipe-driven helper. It never constructs the reader or restores its session.
int main(int argc, const char* argv[]) {
    if (argc != 2 || strcmp(argv[1], "--collection-companion") != 0) return 2;
    return SPDFRunCollectionCompanion();
}
