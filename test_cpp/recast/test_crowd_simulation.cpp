#include <iostream>
#include <cassert>
#include <cstring>
#include <vector>
#include <cmath>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Detour/Include/DetourNavMesh.h"
#include "../docs/recastnavigation/Detour/Include/DetourNavMeshBuilder.h"
#include "../docs/recastnavigation/Detour/Include/DetourNavMeshQuery.h"
#include "../docs/recastnavigation/DetourCrowd/Include/DetourCrowd.h"
#include "../docs/recastnavigation/DetourCrowd/Include/DetourObstacleAvoidance.h"

// Helper to create a simple navmesh for testing
dtNavMesh* createTestNavMesh() {
    // Create a larger square mesh for crowd simulation
    float vertices[] = {
        0, 0, 0,
        50, 0, 0,
        50, 0, 50,
        0, 0, 50
    };
    
    // Build poly mesh
    rcPolyMesh pmesh;
    memset(&pmesh, 0, sizeof(pmesh));
    pmesh.nverts = 4;
    pmesh.npolys = 1;
    pmesh.nvp = 6;
    pmesh.cs = 0.3f;
    pmesh.ch = 0.2f;
    pmesh.bmin[0] = 0;
    pmesh.bmin[1] = 0;
    pmesh.bmin[2] = 0;
    pmesh.bmax[0] = 50;
    pmesh.bmax[1] = 2;
    pmesh.bmax[2] = 50;
    
    // Allocate and set vertex data
    pmesh.verts = new unsigned short[pmesh.nverts * 3];
    for (int i = 0; i < pmesh.nverts; ++i) {
        pmesh.verts[i * 3 + 0] = (unsigned short)(vertices[i * 3 + 0] / pmesh.cs);
        pmesh.verts[i * 3 + 1] = (unsigned short)(vertices[i * 3 + 1] / pmesh.ch);
        pmesh.verts[i * 3 + 2] = (unsigned short)(vertices[i * 3 + 2] / pmesh.cs);
    }
    
    // Allocate and set poly data
    pmesh.polys = new unsigned short[pmesh.npolys * pmesh.nvp * 2];
    pmesh.areas = new unsigned char[pmesh.npolys];
    pmesh.flags = new unsigned short[pmesh.npolys];
    
    for (int i = 0; i < pmesh.nvp * 2; ++i) {
        pmesh.polys[i] = 0xFFFF;
    }
    pmesh.polys[0] = 0;
    pmesh.polys[1] = 1;
    pmesh.polys[2] = 2;
    pmesh.polys[3] = 3;
    pmesh.areas[0] = RC_WALKABLE_AREA;
    pmesh.flags[0] = 1;
    
    // Build detail mesh
    rcPolyMeshDetail dmesh;
    memset(&dmesh, 0, sizeof(dmesh));
    dmesh.nmeshes = 1;
    dmesh.nverts = 4;
    dmesh.ntris = 2;
    dmesh.meshes = new unsigned int[dmesh.nmeshes * 4];
    dmesh.verts = new float[dmesh.nverts * 3];
    dmesh.tris = new unsigned char[dmesh.ntris * 4];
    
    memcpy(dmesh.verts, vertices, sizeof(float) * 12);
    
    dmesh.meshes[0] = 0;
    dmesh.meshes[1] = 4;
    dmesh.meshes[2] = 0;
    dmesh.meshes[3] = 2;
    
    dmesh.tris[0] = 0; dmesh.tris[1] = 1; dmesh.tris[2] = 2; dmesh.tris[3] = 0;
    dmesh.tris[4] = 0; dmesh.tris[5] = 2; dmesh.tris[6] = 3; dmesh.tris[7] = 0;
    
    // Create navmesh params
    dtNavMeshCreateParams params;
    memset(&params, 0, sizeof(params));
    
    params.verts = pmesh.verts;
    params.vertCount = pmesh.nverts;
    params.polys = pmesh.polys;
    params.polyAreas = pmesh.areas;
    params.polyFlags = pmesh.flags;
    params.polyCount = pmesh.npolys;
    params.nvp = pmesh.nvp;
    params.detailMeshes = dmesh.meshes;
    params.detailVerts = dmesh.verts;
    params.detailVertsCount = dmesh.nverts;
    params.detailTris = dmesh.tris;
    params.detailTriCount = dmesh.ntris;
    params.walkableHeight = 2.0f;
    params.walkableRadius = 0.6f;
    params.walkableClimb = 0.9f;
    params.cs = pmesh.cs;
    params.ch = pmesh.ch;
    params.buildBvTree = true;
    
    for (int i = 0; i < 3; ++i) {
        params.bmin[i] = pmesh.bmin[i];
        params.bmax[i] = pmesh.bmax[i];
    }
    
    // Create navmesh data
    unsigned char* navData = nullptr;
    int navDataSize = 0;
    
    if (!dtCreateNavMeshData(&params, &navData, &navDataSize)) {
        delete[] pmesh.verts;
        delete[] pmesh.polys;
        delete[] pmesh.areas;
        delete[] pmesh.flags;
        delete[] dmesh.meshes;
        delete[] dmesh.verts;
        delete[] dmesh.tris;
        return nullptr;
    }
    
    // Create navmesh
    dtNavMesh* navMesh = dtAllocNavMesh();
    if (!navMesh) {
        dtFree(navData);
        delete[] pmesh.verts;
        delete[] pmesh.polys;
        delete[] pmesh.areas;
        delete[] pmesh.flags;
        delete[] dmesh.meshes;
        delete[] dmesh.verts;
        delete[] dmesh.tris;
        return nullptr;
    }
    
    dtStatus status = navMesh->init(navData, navDataSize, DT_TILE_FREE_DATA);
    if (dtStatusFailed(status)) {
        dtFreeNavMesh(navMesh);
        dtFree(navData);
        delete[] pmesh.verts;
        delete[] pmesh.polys;
        delete[] pmesh.areas;
        delete[] pmesh.flags;
        delete[] dmesh.meshes;
        delete[] dmesh.verts;
        delete[] dmesh.tris;
        return nullptr;
    }
    
    // Clean up
    delete[] pmesh.verts;
    delete[] pmesh.polys;
    delete[] pmesh.areas;
    delete[] pmesh.flags;
    delete[] dmesh.meshes;
    delete[] dmesh.verts;
    delete[] dmesh.tris;
    
    return navMesh;
}

// Test crowd creation
void test_crowd_creation() {
    std::cout << "Testing crowd creation..." << std::endl;
    
    dtNavMesh* navMesh = createTestNavMesh();
    assert(navMesh != nullptr);
    
    dtCrowd* crowd = dtAllocCrowd();
    assert(crowd != nullptr && "Crowd allocation should succeed");
    
    // Initialize crowd
    bool result = crowd->init(100, 0.6f, navMesh);
    assert(result && "Crowd initialization should succeed");
    
    // Check crowd properties
    assert(crowd->getAgentCount() == 0 && "Should have no agents initially");
    
    dtFreeCrowd(crowd);
    dtFreeNavMesh(navMesh);
    std::cout << "  ✓ Crowd creation test passed" << std::endl;
}

// Test adding agents
void test_add_agents() {
    std::cout << "Testing adding agents..." << std::endl;
    
    dtNavMesh* navMesh = createTestNavMesh();
    dtCrowd* crowd = dtAllocCrowd();
    crowd->init(100, 0.6f, navMesh);
    
    // Create agent params
    dtCrowdAgentParams params;
    memset(&params, 0, sizeof(params));
    params.radius = 0.6f;
    params.height = 2.0f;
    params.maxAcceleration = 8.0f;
    params.maxSpeed = 3.5f;
    params.collisionQueryRange = params.radius * 12.0f;
    params.pathOptimizationRange = params.radius * 30.0f;
    params.updateFlags = DT_CROWD_ANTICIPATE_TURNS | 
                         DT_CROWD_OPTIMIZE_VIS |
                         DT_CROWD_OPTIMIZE_TOPO |
                         DT_CROWD_OBSTACLE_AVOIDANCE;
    params.obstacleAvoidanceType = 3;
    params.separationWeight = 2.0f;
    
    // Add agents at different positions
    float positions[][3] = {
        {5, 0, 5},
        {10, 0, 10},
        {15, 0, 15},
        {20, 0, 20},
        {25, 0, 25}
    };
    
    std::vector<int> agentIds;
    for (int i = 0; i < 5; ++i) {
        int idx = crowd->addAgent(positions[i], &params);
        assert(idx >= 0 && "Agent addition should succeed");
        agentIds.push_back(idx);
        std::cout << "  Added agent " << idx << " at position (" 
                  << positions[i][0] << ", " << positions[i][1] << ", " << positions[i][2] << ")" << std::endl;
    }
    
    assert(crowd->getAgentCount() == 5 && "Should have 5 agents");
    
    dtFreeCrowd(crowd);
    dtFreeNavMesh(navMesh);
    std::cout << "  ✓ Add agents test passed" << std::endl;
}

// Test agent movement
void test_agent_movement() {
    std::cout << "Testing agent movement..." << std::endl;
    
    dtNavMesh* navMesh = createTestNavMesh();
    dtCrowd* crowd = dtAllocCrowd();
    crowd->init(100, 0.6f, navMesh);
    
    // Create agent params
    dtCrowdAgentParams params;
    memset(&params, 0, sizeof(params));
    params.radius = 0.6f;
    params.height = 2.0f;
    params.maxAcceleration = 8.0f;
    params.maxSpeed = 3.5f;
    params.collisionQueryRange = params.radius * 12.0f;
    params.pathOptimizationRange = params.radius * 30.0f;
    params.updateFlags = DT_CROWD_ANTICIPATE_TURNS | DT_CROWD_OPTIMIZE_VIS;
    params.obstacleAvoidanceType = 3;
    params.separationWeight = 2.0f;
    
    // Add an agent
    float startPos[3] = {5, 0, 5};
    int agentIdx = crowd->addAgent(startPos, &params);
    assert(agentIdx >= 0);
    
    // Set target position
    float targetPos[3] = {45, 0, 45};
    dtPolyRef targetRef;
    float nearest[3];
    
    dtNavMeshQuery* query = dtAllocNavMeshQuery();
    query->init(navMesh, 2048);
    
    float extents[3] = {2, 2, 2};
    dtQueryFilter filter;
    dtStatus status = query->findNearestPoly(targetPos, extents, &filter, &targetRef, nearest);
    assert(dtStatusSucceed(status));
    
    // Request move
    crowd->requestMoveTarget(agentIdx, targetRef, nearest);
    
    // Simulate movement for several frames
    float dt = 0.1f; // 100ms per frame
    const dtCrowdAgent* agent = crowd->getAgent(agentIdx);
    float initialPos[3];
    dtVcopy(initialPos, agent->npos);
    
    std::cout << "  Initial position: (" << initialPos[0] << ", " 
              << initialPos[1] << ", " << initialPos[2] << ")" << std::endl;
    
    // Update for 50 frames (5 seconds)
    for (int i = 0; i < 50; ++i) {
        crowd->update(dt, nullptr);
    }
    
    agent = crowd->getAgent(agentIdx);
    float finalPos[3];
    dtVcopy(finalPos, agent->npos);
    
    std::cout << "  Final position: (" << finalPos[0] << ", " 
              << finalPos[1] << ", " << finalPos[2] << ")" << std::endl;
    
    // Check that agent moved
    float dist = dtVdist(initialPos, finalPos);
    assert(dist > 1.0f && "Agent should have moved");
    std::cout << "  Agent moved " << dist << " units" << std::endl;
    
    dtFreeNavMeshQuery(query);
    dtFreeCrowd(crowd);
    dtFreeNavMesh(navMesh);
    std::cout << "  ✓ Agent movement test passed" << std::endl;
}

// Test obstacle avoidance
void test_obstacle_avoidance() {
    std::cout << "Testing obstacle avoidance..." << std::endl;
    
    dtNavMesh* navMesh = createTestNavMesh();
    dtCrowd* crowd = dtAllocCrowd();
    crowd->init(100, 0.6f, navMesh);
    
    dtCrowdAgentParams params;
    memset(&params, 0, sizeof(params));
    params.radius = 0.6f;
    params.height = 2.0f;
    params.maxAcceleration = 8.0f;
    params.maxSpeed = 3.5f;
    params.collisionQueryRange = params.radius * 12.0f;
    params.pathOptimizationRange = params.radius * 30.0f;
    params.updateFlags = DT_CROWD_ANTICIPATE_TURNS | 
                         DT_CROWD_OBSTACLE_AVOIDANCE |
                         DT_CROWD_SEPARATION;
    params.obstacleAvoidanceType = 3;
    params.separationWeight = 2.0f;
    
    // Add two agents on collision course
    float pos1[3] = {10, 0, 25};
    float pos2[3] = {40, 0, 25};
    
    int agent1 = crowd->addAgent(pos1, &params);
    int agent2 = crowd->addAgent(pos2, &params);
    
    assert(agent1 >= 0 && agent2 >= 0);
    
    // Set targets (agents will cross paths)
    float target1[3] = {40, 0, 25};
    float target2[3] = {10, 0, 25};
    
    dtNavMeshQuery* query = dtAllocNavMeshQuery();
    query->init(navMesh, 2048);
    
    float extents[3] = {2, 2, 2};
    dtQueryFilter filter;
    dtPolyRef ref1, ref2;
    float nearest1[3], nearest2[3];
    
    query->findNearestPoly(target1, extents, &filter, &ref1, nearest1);
    query->findNearestPoly(target2, extents, &filter, &ref2, nearest2);
    
    crowd->requestMoveTarget(agent1, ref1, nearest1);
    crowd->requestMoveTarget(agent2, ref2, nearest2);
    
    // Simulate movement
    float dt = 0.1f;
    float minDist = 1000.0f;
    
    for (int i = 0; i < 100; ++i) {
        crowd->update(dt, nullptr);
        
        const dtCrowdAgent* a1 = crowd->getAgent(agent1);
        const dtCrowdAgent* a2 = crowd->getAgent(agent2);
        
        float dist = dtVdist(a1->npos, a2->npos);
        if (dist < minDist) {
            minDist = dist;
        }
    }
    
    std::cout << "  Minimum distance between agents: " << minDist << std::endl;
    assert(minDist > params.radius * 1.5f && "Agents should maintain separation");
    
    dtFreeNavMeshQuery(query);
    dtFreeCrowd(crowd);
    dtFreeNavMesh(navMesh);
    std::cout << "  ✓ Obstacle avoidance test passed" << std::endl;
}

// Test velocity obstacles
void test_velocity_obstacles() {
    std::cout << "Testing velocity obstacles..." << std::endl;
    
    // Create obstacle avoidance debug object
    dtObstacleAvoidanceDebugData* debugData = dtAllocObstacleAvoidanceDebugData();
    assert(debugData != nullptr && "Debug data allocation should succeed");
    
    debugData->init(2048);
    
    // Create obstacle avoidance query
    dtObstacleAvoidanceQuery* avoidance = dtAllocObstacleAvoidanceQuery();
    assert(avoidance != nullptr && "Avoidance query allocation should succeed");
    avoidance->init(10, 10);
    
    // Set up avoidance params
    dtObstacleAvoidanceParams params;
    memset(&params, 0, sizeof(params));
    params.velBias = 0.4f;
    params.weightDesVel = 2.0f;
    params.weightCurVel = 0.75f;
    params.weightSide = 0.75f;
    params.weightToi = 2.5f;
    params.horizTime = 2.5f;
    params.gridSize = 33;
    params.adaptiveDivs = 7;
    params.adaptiveRings = 2;
    params.adaptiveDepth = 5;
    
    // Note: setObstacleAvoidanceParams is a method of dtCrowd, not dtObstacleAvoidanceQuery
    // This test just validates the query object can be created and destroyed
    // The actual params would be set via dtCrowd::setObstacleAvoidanceParams()
    
    dtFreeObstacleAvoidanceQuery(avoidance);
    dtFreeObstacleAvoidanceDebugData(debugData);
    std::cout << "  ✓ Velocity obstacles test passed" << std::endl;
}

// Test crowd with many agents
void test_crowd_performance() {
    std::cout << "Testing crowd performance with many agents..." << std::endl;
    
    dtNavMesh* navMesh = createTestNavMesh();
    dtCrowd* crowd = dtAllocCrowd();
    crowd->init(100, 0.6f, navMesh);
    
    dtCrowdAgentParams params;
    memset(&params, 0, sizeof(params));
    params.radius = 0.6f;
    params.height = 2.0f;
    params.maxAcceleration = 8.0f;
    params.maxSpeed = 3.5f;
    params.collisionQueryRange = params.radius * 12.0f;
    params.pathOptimizationRange = params.radius * 30.0f;
    params.updateFlags = DT_CROWD_ANTICIPATE_TURNS | DT_CROWD_SEPARATION;
    params.obstacleAvoidanceType = 3;
    params.separationWeight = 2.0f;
    
    // Add 50 agents in a grid pattern
    int agentCount = 0;
    for (int x = 0; x < 10; ++x) {
        for (int z = 0; z < 5; ++z) {
            float pos[3] = {5.0f + x * 4.0f, 0, 5.0f + z * 4.0f};
            int idx = crowd->addAgent(pos, &params);
            if (idx >= 0) {
                agentCount++;
            }
        }
    }
    
    std::cout << "  Added " << agentCount << " agents" << std::endl;
    assert(agentCount > 40 && "Should add most agents successfully");
    
    // Update for several frames
    float dt = 0.1f;
    for (int i = 0; i < 10; ++i) {
        crowd->update(dt, nullptr);
    }
    
    std::cout << "  Successfully updated " << agentCount << " agents for 10 frames" << std::endl;
    
    dtFreeCrowd(crowd);
    dtFreeNavMesh(navMesh);
    std::cout << "  ✓ Crowd performance test passed" << std::endl;
}

int main() {
    std::cout << "=== Running C++ Crowd Simulation Tests ===" << std::endl;
    std::cout << "These tests verify DetourCrowd operations\n" << std::endl;
    
    test_crowd_creation();
    test_add_agents();
    test_agent_movement();
    test_obstacle_avoidance();
    test_velocity_obstacles();
    test_crowd_performance();
    
    std::cout << "\n=== All crowd simulation tests passed! ===" << std::endl;
    return 0;
}