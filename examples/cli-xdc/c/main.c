#include <stdio.h>

int main(int argc, char **argv) {
  puts(argc > 1 ? argv[1] : "Hello from C");
  return 0;
}
