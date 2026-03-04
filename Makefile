# Unified Makefile: ASM primitives + Rust workspace integration
# (Silenced stdout version)

# ----------------------------------------------------------------------
# ASM build configuration (unchanged)
# ----------------------------------------------------------------------
NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -DPIC -I./include

# Sources
SRC_ASM      = src/memfd.asm src/writer.asm src/executor.asm src/util.asm src/_start.asm
TEST_ASM     = tests/test_memfd.asm tests/test_writer.asm tests/test_executor.asm \
               tests/test_sealing.asm tests/test_load_and_exec.asm
OBJ_SRC      = $(addprefix build/,$(notdir $(SRC_ASM:.asm=.o)))
OBJ_TEST     = $(addprefix build/,$(notdir $(TEST_ASM:.asm=.o)))
TARGETS      = build/test_memfd build/test_writer build/test_executor \
               build/test_sealing build/test_load_and_exec

# Payload
PAYLOAD_SRC  = payload/exit42.asm
PAYLOAD_BIN  = payload/implant.bin

# Rust project directory
RUST_DIR     = rust_src

.PHONY: all clean asm
.PHONY: build release test check fmt lint doc run help

# ----------------------------------------------------------------------
# Default target: build ASM tests (original behaviour)
# ----------------------------------------------------------------------
all: $(PAYLOAD_BIN) $(TARGETS)

# Build all ASM objects and payload (dependency for Rust targets)
asm: $(OBJ_SRC) $(PAYLOAD_BIN)

# ----------------------------------------------------------------------
# ASM build rules (exactly as before, commands silenced)
# ----------------------------------------------------------------------
$(PAYLOAD_BIN): $(PAYLOAD_SRC)
	@mkdir -p payload
	@$(NASM) -f elf64 $< -o $(@:.bin=.o)
	@$(LD) -static -o $@ $(@:.bin=.o)

build/test_memfd: build/memfd.o build/test_memfd.o
	@$(LD) -o $@ $^

build/test_writer: build/memfd.o build/writer.o build/test_writer.o
	@$(LD) -o $@ $^

build/test_executor: build/memfd.o build/writer.o build/executor.o build/test_executor.o
	@$(LD) -o $@ $^

build/test_sealing: build/memfd.o build/writer.o build/util.o build/test_sealing.o
	@$(LD) -o $@ $^

build/test_load_and_exec: build/memfd.o build/writer.o build/executor.o build/util.o \
                          build/_start.o build/test_load_and_exec.o
	@$(LD) -o $@ $^

build/memfd.o: src/memfd.asm include/syscalls.inc
	@mkdir -p build
	@$(NASM) $(NASMFLAGS) -o $@ $<

build/writer.o: src/writer.asm include/syscalls.inc
	@mkdir -p build
	@$(NASM) $(NASMFLAGS) -o $@ $<

build/executor.o: src/executor.asm include/syscalls.inc
	@mkdir -p build
	@$(NASM) $(NASMFLAGS) -o $@ $<

build/util.o: src/util.asm include/syscalls.inc
	@mkdir -p build
	@$(NASM) $(NASMFLAGS) -o $@ $<

build/_start.o: src/_start.asm include/syscalls.inc
	@mkdir -p build
	@$(NASM) $(NASMFLAGS) -o $@ $<

build/test_memfd.o: tests/test_memfd.asm include/syscalls.inc
	@mkdir -p build
	@$(NASM) $(NASMFLAGS) -o $@ $<

build/test_writer.o: tests/test_writer.asm include/syscalls.inc
	@mkdir -p build
	@$(NASM) $(NASMFLAGS) -o $@ $<

build/test_executor.o: tests/test_executor.asm include/syscalls.inc $(PAYLOAD_BIN)
	@mkdir -p build
	@$(NASM) $(NASMFLAGS) -o $@ $<

build/test_sealing.o: tests/test_sealing.asm include/syscalls.inc
	@mkdir -p build
	@$(NASM) $(NASMFLAGS) -o $@ $<

build/test_load_and_exec.o: tests/test_load_and_exec.asm include/syscalls.inc $(PAYLOAD_BIN)
	@mkdir -p build
	@$(NASM) $(NASMFLAGS) -o $@ $<

# ----------------------------------------------------------------------
# Rust workspace commands (Shamus style, with ASM dependency, silenced)
# ----------------------------------------------------------------------

# Build debug version of the Rust workspace
build: asm
	@cd $(RUST_DIR) && cargo build

# Build release version of the Rust workspace
release: asm
	@cd $(RUST_DIR) && cargo build --release

# Run all Rust tests (unit + integration)
test: asm
	@cd $(RUST_DIR) && cargo test --workspace

# Fast check (no code generation)
check: asm
	@cd $(RUST_DIR) && cargo check --workspace

# Format Rust code
fmt:
	@cd $(RUST_DIR) && cargo fmt --all

# Run clippy lints
lint: asm
	@cd $(RUST_DIR) && cargo clippy --workspace -- -D warnings

# Generate and open Rust documentation
doc:
	@cd $(RUST_DIR) && cargo doc --workspace --no-deps --open

# Run the Rust test binary (the main that calls load_and_exec)
# Usage: make run [ARGS="--sealed"]  (any arguments are passed to the binary)
run: asm
	@cd $(RUST_DIR) && cargo run -- $(ARGS)

# ----------------------------------------------------------------------
# Clean everything (ASM + Rust) – errors from cargo clean are ignored
# ----------------------------------------------------------------------
clean:
	@rm -rf build payload/*.o payload/implant.bin
	@-cd $(RUST_DIR) && cargo clean 2>/dev/null || true

# ----------------------------------------------------------------------
# Help (already silenced)
# ----------------------------------------------------------------------
help:
	@echo "Available targets:"
	@echo "  all                Build ASM tests (default)"
	@echo "  asm                Build ASM objects and payload (dependency for Rust)"
	@echo ""
	@echo "  build              Build Rust workspace (debug)"
	@echo "  release            Build Rust workspace (release)"
	@echo "  test               Run Rust tests (unit + integration)"
	@echo "  check              Fast Rust compilation check"
	@echo "  fmt                Format Rust code"
	@echo "  lint               Run Rust clippy"
	@echo "  doc                Generate and open Rust docs"
	@echo "  run                Run Rust test binary (pass ARGS=...)"
	@echo "  clean              Remove all build artifacts (ASM + Rust)"
	@echo "  help               Show this help"
