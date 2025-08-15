#include <iostream>
#include <cmath>
#include <cstring>
#include <vector>
#include <Recast.h>
#include <DetourNavMesh.h>
#include <DetourNavMeshBuilder.h>
#include <DetourNavMeshQuery.h>
#include <DetourCrowd.h>
#include <DetourPathQueue.h>
#include <DetourPathCorridor.h>
#include <DetourCommon.h>

// Helper function to create a simple test nav mesh
dtNavMesh* createTestNavMesh() {
    dtNavMesh* navMesh = dtAllocNavMesh();
    if (!navMesh) return nullptr;

    // Create a simple nav mesh with a single tile
    dtNavMeshParams params;
    memset(&params, 0, sizeof(params));
    params.orig[0] = 0.0f;
    params.orig[1] = 0.0f;
    params.orig[2] = 0.0f;
    params.tileWidth = 100.0f;
    params.tileHeight = 100.0f;
    params.maxTiles = 16;
    params.maxPolys = 256;

    dtStatus status = navMesh->init(&params);
    if (!dtStatusSucceed(status)) {
        dtFreeNavMesh(navMesh);
        return nullptr;
    }

    // For testing purposes, we'll use an empty nav mesh
    // In real use, you'd add tiles with actual polygon data
    
    return navMesh;
}

void test_path_queue_request_response_cycle() {
    std::cout << "\n=== Testing Path Queue Request Response Cycle ===" << std::endl;

    dtNavMesh* navMesh = createTestNavMesh();
    if (!navMesh) {
        std::cerr << "Failed to create test nav mesh" << std::endl;
        return;
    }

    dtNavMeshQuery* navQuery = dtAllocNavMeshQuery();
    if (!navQuery) {
        dtFreeNavMesh(navMesh);
        return;
    }

    dtStatus status = navQuery->init(navMesh, 256);
    if (!dtStatusSucceed(status)) {
        std::cerr << "Failed to init nav query" << std::endl;
        dtFreeNavMeshQuery(navQuery);
        dtFreeNavMesh(navMesh);
        return;
    }

    // Create path queue
    dtPathQueue* queue = new dtPathQueue();
    
    // Initialize path queue with known parameters
    bool initSuccess = queue->init(64, 512, navMesh);
    if (!initSuccess) {
        std::cerr << "Failed to initialize path queue" << std::endl;
        delete queue;
        dtFreeNavMeshQuery(navQuery);
        dtFreeNavMesh(navMesh);
        return;
    }

    // Test exact initial state
    std::cout << "Queue initialized with max path size: 64, max search nodes: 512" << std::endl;

    // Find nearest polys for testing
    float startPos[3] = {5.0f, 0.0f, 5.0f};
    float endPos[3] = {25.0f, 0.0f, 25.0f};
    float extents[3] = {2.0f, 4.0f, 2.0f};
    
    dtQueryFilter filter;
    filter.setIncludeFlags(0xffff);
    filter.setExcludeFlags(0);

    dtPolyRef startRef = 0;
    dtPolyRef endRef = 0;
    float nearestStartPos[3];
    float nearestEndPos[3];
    
    status = navQuery->findNearestPoly(startPos, extents, &filter, &startRef, nearestStartPos);
    if (!dtStatusSucceed(status) || startRef == 0) {
        std::cerr << "Failed to find start poly" << std::endl;
    }

    status = navQuery->findNearestPoly(endPos, extents, &filter, &endRef, nearestEndPos);
    if (!dtStatusSucceed(status) || endRef == 0) {
        std::cerr << "Failed to find end poly" << std::endl;
    }

    if (startRef && endRef) {
        // Request path
        dtPathQueueRef pathRef = queue->request(startRef, endRef, nearestStartPos, nearestEndPos, &filter);
        
        if (pathRef != DT_PATHQ_INVALID) {
            std::cout << "Path request submitted with reference: " << pathRef << std::endl;
            
            // Update queue to process request
            queue->update(10);
            
            // Check status
            dtStatus pathStatus = queue->getRequestStatus(pathRef);
            
            if (dtStatusSucceed(pathStatus)) {
                // Get path result
                dtPolyRef path[32];
                int pathCount = 0;
                queue->getPathResult(pathRef, path, &pathCount, 32);
                
                std::cout << "Path found with " << pathCount << " polygons" << std::endl;
                
                if (pathCount > 0 && path[0] == startRef) {
                    std::cout << "Path correctly starts with start reference" << std::endl;
                }
            } else if (dtStatusInProgress(pathStatus)) {
                std::cout << "Path request still in progress" << std::endl;
            } else {
                std::cout << "Path request failed" << std::endl;
            }
        } else {
            std::cerr << "Failed to submit path request" << std::endl;
        }
    }

    delete queue;
    dtFreeNavMeshQuery(navQuery);
    dtFreeNavMesh(navMesh);
    
    std::cout << "Test completed" << std::endl;
}

void test_path_corridor_reset_with_exact_values() {
    std::cout << "\n=== Testing Path Corridor Reset With Exact Values ===" << std::endl;

    dtNavMesh* navMesh = createTestNavMesh();
    if (!navMesh) {
        std::cerr << "Failed to create test nav mesh" << std::endl;
        return;
    }

    dtNavMeshQuery* navQuery = dtAllocNavMeshQuery();
    navQuery->init(navMesh, 256);

    // Create path corridor
    dtPathCorridor* corridor = new dtPathCorridor();
    corridor->init(256);

    // Find a valid poly reference
    float searchPos[3] = {10.0f, 0.0f, 10.0f};
    float extents[3] = {5.0f, 5.0f, 5.0f};
    dtQueryFilter filter;
    filter.setIncludeFlags(0xffff);
    filter.setExcludeFlags(0);

    dtPolyRef startRef = 0;
    float nearestPos[3];
    
    dtStatus status = navQuery->findNearestPoly(searchPos, extents, &filter, &startRef, nearestPos);
    
    if (dtStatusSucceed(status) && startRef != 0) {
        // Reset corridor with single polygon
        corridor->reset(startRef, nearestPos);
        
        // Verify corridor state
        int pathCount = corridor->getPathCount();
        if (pathCount == 1) {
            std::cout << "Corridor reset with single polygon" << std::endl;
        } else {
            std::cerr << "Expected path count 1, got " << pathCount << std::endl;
        }
        
        // Get current position
        const float* pos = corridor->getPos();
        bool posMatch = (std::abs(pos[0] - nearestPos[0]) < 0.001f &&
                        std::abs(pos[1] - nearestPos[1]) < 0.001f &&
                        std::abs(pos[2] - nearestPos[2]) < 0.001f);
        
        if (posMatch) {
            std::cout << "Corridor position matches reset position" << std::endl;
        } else {
            std::cerr << "Corridor position doesn't match" << std::endl;
        }
        
        // Get target position
        const float* target = corridor->getTarget();
        bool targetMatch = (std::abs(target[0] - nearestPos[0]) < 0.001f &&
                           std::abs(target[1] - nearestPos[1]) < 0.001f &&
                           std::abs(target[2] - nearestPos[2]) < 0.001f);
        
        if (targetMatch) {
            std::cout << "Corridor target matches reset position" << std::endl;
        } else {
            std::cerr << "Corridor target doesn't match" << std::endl;
        }
        
        // Verify first polygon
        dtPolyRef firstRef = corridor->getFirstPoly();
        if (firstRef == startRef) {
            std::cout << "First polygon reference matches" << std::endl;
        } else {
            std::cerr << "First polygon reference doesn't match" << std::endl;
        }
        
        // Verify last polygon
        dtPolyRef lastRef = corridor->getLastPoly();
        if (lastRef == startRef) {
            std::cout << "Last polygon reference matches (single poly path)" << std::endl;
        } else {
            std::cerr << "Last polygon reference doesn't match" << std::endl;
        }
    } else {
        std::cerr << "Failed to find valid start polygon" << std::endl;
    }

    delete corridor;
    dtFreeNavMeshQuery(navQuery);
    dtFreeNavMesh(navMesh);
    
    std::cout << "Test completed" << std::endl;
}

int main() {
    std::cout << "=== DetourCrowd Pathfinding Tests ===" << std::endl;

    test_path_queue_request_response_cycle();
    test_path_corridor_reset_with_exact_values();

    std::cout << "\n=== All tests completed ===" << std::endl;
    return 0;
}