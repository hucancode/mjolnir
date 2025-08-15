# Makefile for C++ Recast/Detour/Crowd tests
# These tests verify the Odin implementation against the original C++ library

CXX = g++
CXXFLAGS = -std=c++11 -Wall -O2 -g -I../docs/recastnavigation/Recast/Include -I../docs/recastnavigation/Detour/Include -I../docs/recastnavigation/DetourCrowd/Include
LDFLAGS = 

# Recast library paths
RECAST_DIR = ../docs/recastnavigation
RECAST_SRC = $(RECAST_DIR)/Recast/Source
DETOUR_SRC = $(RECAST_DIR)/Detour/Source
CROWD_SRC = $(RECAST_DIR)/DetourCrowd/Source

# Source files for Recast
RECAST_SOURCES = \
	$(RECAST_SRC)/Recast.cpp \
	$(RECAST_SRC)/RecastAlloc.cpp \
	$(RECAST_SRC)/RecastArea.cpp \
	$(RECAST_SRC)/RecastAssert.cpp \
	$(RECAST_SRC)/RecastContour.cpp \
	$(RECAST_SRC)/RecastFilter.cpp \
	$(RECAST_SRC)/RecastLayers.cpp \
	$(RECAST_SRC)/RecastMesh.cpp \
	$(RECAST_SRC)/RecastMeshDetail.cpp \
	$(RECAST_SRC)/RecastRasterization.cpp \
	$(RECAST_SRC)/RecastRegion.cpp

# Source files for Detour
DETOUR_SOURCES = \
	$(DETOUR_SRC)/DetourAlloc.cpp \
	$(DETOUR_SRC)/DetourAssert.cpp \
	$(DETOUR_SRC)/DetourCommon.cpp \
	$(DETOUR_SRC)/DetourNavMesh.cpp \
	$(DETOUR_SRC)/DetourNavMeshBuilder.cpp \
	$(DETOUR_SRC)/DetourNavMeshQuery.cpp \
	$(DETOUR_SRC)/DetourNode.cpp

# Source files for DetourCrowd
CROWD_SOURCES = \
	$(CROWD_SRC)/DetourCrowd.cpp \
	$(CROWD_SRC)/DetourLocalBoundary.cpp \
	$(CROWD_SRC)/DetourObstacleAvoidance.cpp \
	$(CROWD_SRC)/DetourPathCorridor.cpp \
	$(CROWD_SRC)/DetourPathQueue.cpp \
	$(CROWD_SRC)/DetourProximityGrid.cpp

# Object files
RECAST_OBJS = $(RECAST_SOURCES:.cpp=.o)
DETOUR_OBJS = $(DETOUR_SOURCES:.cpp=.o)
CROWD_OBJS = $(CROWD_SOURCES:.cpp=.o)

# Binary directory
BIN_DIR = bin

# Test source directories
RECAST_TEST_DIR = recast
DETOUR_TEST_DIR = detour
CROWD_TEST_DIR = crowd

# Test executables
RECAST_TESTS = $(patsubst $(RECAST_TEST_DIR)/%.cpp,$(BIN_DIR)/%,$(wildcard $(RECAST_TEST_DIR)/*.cpp))
DETOUR_TESTS = $(patsubst $(DETOUR_TEST_DIR)/%.cpp,$(BIN_DIR)/%,$(wildcard $(DETOUR_TEST_DIR)/*.cpp))
CROWD_TESTS = $(patsubst $(CROWD_TEST_DIR)/%.cpp,$(BIN_DIR)/%,$(wildcard $(CROWD_TEST_DIR)/*.cpp))

TESTS = $(RECAST_TESTS) $(DETOUR_TESTS) $(CROWD_TESTS)

# Default target
all: $(BIN_DIR) $(TESTS)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

# Build Recast library objects
$(RECAST_OBJS): %.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Build Detour library objects
$(DETOUR_OBJS): %.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Build Crowd library objects
$(CROWD_OBJS): %.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Pattern rules for test executables
$(BIN_DIR)/%: $(RECAST_TEST_DIR)/%.cpp $(RECAST_OBJS)
	$(CXX) $(CXXFLAGS) $< $(RECAST_OBJS) -o $@ $(LDFLAGS)

$(BIN_DIR)/%: $(DETOUR_TEST_DIR)/%.cpp $(RECAST_OBJS) $(DETOUR_OBJS)
	$(CXX) $(CXXFLAGS) $< $(RECAST_OBJS) $(DETOUR_OBJS) -o $@ $(LDFLAGS)

$(BIN_DIR)/%: $(CROWD_TEST_DIR)/%.cpp $(RECAST_OBJS) $(DETOUR_OBJS) $(CROWD_OBJS)
	$(CXX) $(CXXFLAGS) $< $(RECAST_OBJS) $(DETOUR_OBJS) $(CROWD_OBJS) -o $@ $(LDFLAGS)

# Run all tests
test: $(TESTS)
	@echo "=== Running all C++ tests ==="
	@for test in $(TESTS); do \
		if [ -f $$test ]; then \
			echo "\nRunning $$test..."; \
			./$$test || exit 1; \
		fi; \
	done
	@echo "\n=== All C++ tests passed ==="

# Clean up
clean:
	rm -f $(RECAST_OBJS) $(DETOUR_OBJS) $(CROWD_OBJS)
	rm -rf $(BIN_DIR)
	rm -f *.o

.PHONY: all test clean