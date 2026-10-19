#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef PHP_VERSION
#define PHP_VERSION "8.4.99"
#endif

#ifndef FIXTURE_NAME
#define FIXTURE_NAME "default"
#endif

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "-v") == 0) {
        printf("PHP %s (cli) synthetic composer fixture\n", PHP_VERSION);
        return 0;
    }

    char cwd[4096];
    if (getcwd(cwd, sizeof(cwd)) == NULL) return 90;
    printf("PHP_FIXTURE=%s\nCWD=%s\n", FIXTURE_NAME, cwd);
    for (int index = 1; index < argc; index++) {
        printf("ARG[%d]=%zu:", index, strlen(argv[index]));
        fwrite(argv[index], 1, strlen(argv[index]), stdout);
        putchar('\n');
    }
    fputs("STDIN:", stdout);
    int byte;
    while ((byte = getchar()) != EOF) putchar(byte);
    fputc('\n', stdout);
    fputs("composer-fixture-stderr\n", stderr);

    for (int index = 1; index < argc; index++) {
        if (strncmp(argv[index], "--exit=", 7) == 0) return atoi(argv[index] + 7);
    }
    return 0;
}
