EXECUTABLE := listcommands
BUILD_DIR := ./build
ASFLAGS := -g

sources := start.S
objects := $(sources:%.S=$(BUILD_DIR)/%.o)

.PHONY: clean
$(EXECUTABLE): $(objects)
	@echo $(sources)
	@echo $(objects)
	ld -n --strip-all $^ -o $@

debug: $(objects)
	ld $^ -o $@

clean:
	rm -r $(BUILD_DIR)

$(BUILD_DIR)/%.o: %.S
	@mkdir -p $(BUILD_DIR)
	as $< -o $@ $(ASFLAGS)
