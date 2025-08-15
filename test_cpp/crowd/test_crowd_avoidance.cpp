#include <iostream>
#include <cmath>
#include <cstring>
#include <vector>
#include <Recast.h>
#include <DetourNavMesh.h>
#include <DetourNavMeshQuery.h>
#include <DetourCrowd.h>
#include <DetourObstacleAvoidance.h>
#include <DetourCommon.h>

void test_obstacle_avoidance_query_circle_exact_values() {
    std::cout << "\n=== Testing Obstacle Avoidance Query Circle Exact Values ===" << std::endl;

    // Create obstacle avoidance query
    dtObstacleAvoidanceQuery* query = new dtObstacleAvoidanceQuery();
    
    // Initialize with exact capacities
    bool initSuccess = query->init(10, 20);
    if (!initSuccess) {
        std::cerr << "Failed to initialize obstacle avoidance query" << std::endl;
        delete query;
        return;
    }
    
    // Verify exact initial state
    int circleCount = query->getObstacleCircleCount();
    int segmentCount = query->getObstacleSegmentCount();
    
    if (circleCount != 0) {
        std::cerr << "Should start with 0 circle obstacles, got " << circleCount << std::endl;
    }
    if (segmentCount != 0) {
        std::cerr << "Should start with 0 segment obstacles, got " << segmentCount << std::endl;
    }
    
    // Add circle obstacle with exact parameters
    float obstaclePos[3] = {5.0f, 0.0f, 5.0f};
    float obstacleVel[3] = {1.0f, 0.0f, 0.0f};
    float obstacleDvel[3] = {0.5f, 0.0f, 0.0f};
    float obstacleRadius = 1.5f;
    float displacement[3] = {0.0f, 0.0f, 1.0f};
    float nextPos[3] = {6.0f, 0.0f, 5.0f};
    
    query->addCircle(obstaclePos, obstacleRadius, obstacleVel, obstacleDvel);
    
    circleCount = query->getObstacleCircleCount();
    if (circleCount != 1) {
        std::cerr << "Should have exactly 1 circle obstacle, got " << circleCount << std::endl;
    }
    
    // Verify exact circle obstacle values
    const dtObstacleCircle* circle = query->getObstacleCircle(0);
    if (circle) {
        bool posMatch = (circle->p[0] == obstaclePos[0] && 
                        circle->p[1] == obstaclePos[1] && 
                        circle->p[2] == obstaclePos[2]);
        bool velMatch = (circle->vel[0] == obstacleVel[0] && 
                        circle->vel[1] == obstacleVel[1] && 
                        circle->vel[2] == obstacleVel[2]);
        bool dvelMatch = (circle->dvel[0] == obstacleDvel[0] && 
                         circle->dvel[1] == obstacleDvel[1] && 
                         circle->dvel[2] == obstacleDvel[2]);
        bool radMatch = (circle->rad == obstacleRadius);
        
        if (!posMatch) std::cerr << "Circle position doesn't match" << std::endl;
        if (!velMatch) std::cerr << "Circle velocity doesn't match" << std::endl;
        if (!dvelMatch) std::cerr << "Circle desired velocity doesn't match" << std::endl;
        if (!radMatch) std::cerr << "Circle radius doesn't match" << std::endl;
        
        if (posMatch && velMatch && dvelMatch && radMatch) {
            std::cout << "Circle obstacle values match exactly" << std::endl;
        }
    }
    
    delete query;
    std::cout << "Test completed" << std::endl;
}

void test_obstacle_avoidance_query_segment_exact_values() {
    std::cout << "\n=== Testing Obstacle Avoidance Query Segment Exact Values ===" << std::endl;

    dtObstacleAvoidanceQuery* query = new dtObstacleAvoidanceQuery();
    query->init(5, 15);
    
    // Add segment obstacle with exact parameters
    float segStart[3] = {0.0f, 0.0f, 0.0f};
    float segEnd[3] = {10.0f, 0.0f, 0.0f};
    
    query->addSegment(segStart, segEnd);
    
    int segmentCount = query->getObstacleSegmentCount();
    if (segmentCount != 1) {
        std::cerr << "Should have exactly 1 segment obstacle, got " << segmentCount << std::endl;
    }
    
    // Verify exact segment obstacle values
    const dtObstacleSegment* segment = query->getObstacleSegment(0);
    if (segment) {
        bool startMatch = (segment->p[0] == segStart[0] && 
                          segment->p[1] == segStart[1] && 
                          segment->p[2] == segStart[2]);
        bool endMatch = (segment->q[0] == segEnd[0] && 
                        segment->q[1] == segEnd[1] && 
                        segment->q[2] == segEnd[2]);
        
        if (!startMatch) std::cerr << "Segment start doesn't match" << std::endl;
        if (!endMatch) std::cerr << "Segment end doesn't match" << std::endl;
        
        if (startMatch && endMatch) {
            std::cout << "Segment obstacle values match exactly" << std::endl;
        }
    }
    
    delete query;
    std::cout << "Test completed" << std::endl;
}

void test_obstacle_avoidance_velocity_sampling_grid() {
    std::cout << "\n=== Testing Obstacle Avoidance Velocity Sampling Grid ===" << std::endl;

    dtObstacleAvoidanceQuery* query = new dtObstacleAvoidanceQuery();
    query->init(5, 10);
    
    // Set up specific avoidance parameters
    dtObstacleAvoidanceParams params;
    memset(&params, 0, sizeof(params));
    params.velBias = 0.4f;
    params.weightDesVel = 2.0f;
    params.weightCurVel = 0.75f;
    params.weightSide = 0.75f;
    params.weightToi = 2.5f;
    params.horizTime = 2.5f;
    params.gridSize = 21;  // Specific grid size for predictable sampling
    params.adaptiveDivs = 7;
    params.adaptiveRings = 2;
    params.adaptiveDepth = 5;
    
    // Add a circular obstacle
    float obstaclePos[3] = {3.0f, 0.0f, 0.0f};
    float obstacleVel[3] = {0.0f, 0.0f, 0.0f};
    float obstacleDvel[3] = {0.0f, 0.0f, 0.0f};
    float obstacleRadius = 1.0f;
    
    query->addCircle(obstaclePos, obstacleRadius, obstacleVel, obstacleDvel);
    
    // Test velocity sampling with exact parameters
    float agentPos[3] = {0.0f, 0.0f, 0.0f};
    float currentVel[3] = {1.0f, 0.0f, 0.0f};  // Moving toward obstacle
    float desiredVel[3] = {2.0f, 0.0f, 0.0f};  // Faster toward obstacle
    float agentRadius = 0.5f;
    float desiredVelMag = dtVlen(desiredVel);
    
    dtObstacleAvoidanceDebugData* debugData = dtAllocObstacleAvoidanceDebugData();
    debugData->init(1000);
    
    // Sample velocity using grid method
    float resultVel[3];
    int sampleCount = query->sampleVelocityGrid(
        agentPos, agentRadius, desiredVelMag,
        currentVel, desiredVel, resultVel,
        &params, debugData
    );
    
    // Verify sampling results
    if (sampleCount <= 0) {
        std::cerr << "Should generate velocity samples" << std::endl;
    } else {
        std::cout << "Generated " << sampleCount << " velocity samples" << std::endl;
    }
    
    int maxSamples = params.gridSize * params.gridSize;
    if (sampleCount > maxSamples) {
        std::cerr << "Sample count " << sampleCount << " exceeds grid capacity " << maxSamples << std::endl;
    }
    
    // Verify result velocity is reasonable (should avoid obstacle)
    float resultSpeed = dtVlen(resultVel);
    if (resultSpeed < 0.0f) {
        std::cerr << "Result velocity should have non-negative magnitude" << std::endl;
    } else {
        std::cout << "Result velocity magnitude: " << resultSpeed << std::endl;
    }
    
    // For this setup, result should not point directly at obstacle
    float toObstacle[3];
    dtVsub(toObstacle, obstaclePos, agentPos);
    dtVnormalize(toObstacle);
    
    if (resultSpeed > 0.01f) {
        float velNormalized[3];
        dtVscale(velNormalized, resultVel, 1.0f / resultSpeed);
        
        float dot = dtVdot(velNormalized, toObstacle);
        std::cout << "Dot product with obstacle direction: " << dot << std::endl;
        
        if (dot < 0.9f) {
            std::cout << "Velocity successfully avoids direct collision course" << std::endl;
        }
    }
    
    dtFreeObstacleAvoidanceDebugData(debugData);
    delete query;
    std::cout << "Test completed" << std::endl;
}

int main() {
    std::cout << "=== DetourCrowd Avoidance Tests ===" << std::endl;

    test_obstacle_avoidance_query_circle_exact_values();
    test_obstacle_avoidance_query_segment_exact_values();
    test_obstacle_avoidance_velocity_sampling_grid();

    std::cout << "\n=== All tests completed ===" << std::endl;
    return 0;
}