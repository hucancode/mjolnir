#include <iostream>
#include <cmath>
#include <cstring>
#include <Recast.h>
#include <DetourNavMesh.h>
#include <DetourNavMeshBuilder.h>
#include <DetourNavMeshQuery.h>
#include <DetourCrowd.h>
#include <DetourCommon.h>

void test_basic_crowd_creation() {
    std::cout << "\n=== Testing Basic Crowd Creation ===" << std::endl;

    // Create simple nav mesh
    dtNavMesh* navMesh = dtAllocNavMesh();
    if (!navMesh) {
        std::cerr << "Failed to allocate nav mesh" << std::endl;
        return;
    }

    dtNavMeshParams params;
    memset(&params, 0, sizeof(params));
    params.orig[0] = 0.0f;
    params.orig[1] = 0.0f;
    params.orig[2] = 0.0f;
    params.tileWidth = 10.0f;
    params.tileHeight = 10.0f;
    params.maxTiles = 1;
    params.maxPolys = 64;

    dtStatus status = navMesh->init(&params);
    if (!dtStatusSucceed(status)) {
        std::cerr << "Nav mesh init failed" << std::endl;
        dtFreeNavMesh(navMesh);
        return;
    }

    // Create nav query
    dtNavMeshQuery* navQuery = dtAllocNavMeshQuery();
    if (!navQuery) {
        std::cerr << "Failed to allocate nav query" << std::endl;
        dtFreeNavMesh(navMesh);
        return;
    }

    status = navQuery->init(navMesh, 256);
    if (!dtStatusSucceed(status)) {
        std::cerr << "Nav query init failed" << std::endl;
        dtFreeNavMeshQuery(navQuery);
        dtFreeNavMesh(navMesh);
        return;
    }

    // Create crowd
    dtCrowd* crowd = dtAllocCrowd();
    if (!crowd) {
        std::cerr << "Failed to allocate crowd" << std::endl;
        dtFreeNavMeshQuery(navQuery);
        dtFreeNavMesh(navMesh);
        return;
    }

    if (!crowd->init(10, 2.0f, navMesh)) {
        std::cerr << "Crowd init failed" << std::endl;
        dtFreeCrowd(crowd);
        dtFreeNavMeshQuery(navQuery);
        dtFreeNavMesh(navMesh);
        return;
    }

    // Test basic properties
    if (crowd->getAgentCount() != 0) {
        std::cerr << "Should have no active agents initially" << std::endl;
    }

    // Test obstacle avoidance params
    dtObstacleAvoidanceParams params_oa;
    memset(&params_oa, 0, sizeof(params_oa));
    params_oa.velBias = 0.4f;
    params_oa.weightDesVel = 2.0f;
    params_oa.weightCurVel = 0.75f;
    params_oa.weightSide = 0.75f;
    params_oa.weightToi = 2.5f;
    params_oa.horizTime = 2.5f;
    params_oa.gridSize = 33;
    params_oa.adaptiveDivs = 7;
    params_oa.adaptiveRings = 2;
    params_oa.adaptiveDepth = 5;

    crowd->setObstacleAvoidanceParams(0, &params_oa);

    const dtObstacleAvoidanceParams* retrieved = crowd->getObstacleAvoidanceParams(0);
    if (!retrieved) {
        std::cerr << "Should retrieve obstacle avoidance params" << std::endl;
    }

    // Test filter access
    const dtQueryFilter* filter = crowd->getFilter(0);
    if (!filter) {
        std::cerr << "Should get filter" << std::endl;
    }

    std::cout << "Basic crowd creation test passed" << std::endl;

    // Clean up
    dtFreeCrowd(crowd);
    dtFreeNavMeshQuery(navQuery);
    dtFreeNavMesh(navMesh);
}

void test_agent_add_remove() {
    std::cout << "\n=== Testing Agent Add/Remove ===" << std::endl;

    // Setup
    dtNavMesh* navMesh = dtAllocNavMesh();
    if (!navMesh) {
        std::cerr << "Failed to allocate nav mesh" << std::endl;
        return;
    }

    dtNavMeshParams params;
    memset(&params, 0, sizeof(params));
    params.orig[0] = 0.0f;
    params.orig[1] = 0.0f;
    params.orig[2] = 0.0f;
    params.tileWidth = 10.0f;
    params.tileHeight = 10.0f;
    params.maxTiles = 1;
    params.maxPolys = 64;

    navMesh->init(&params);

    dtNavMeshQuery* navQuery = dtAllocNavMeshQuery();
    navQuery->init(navMesh, 256);

    dtCrowd* crowd = dtAllocCrowd();
    crowd->init(5, 2.0f, navMesh);

    // Test adding agents
    dtCrowdAgentParams agentParams;
    memset(&agentParams, 0, sizeof(agentParams));
    agentParams.radius = 0.5f;
    agentParams.height = 2.0f;
    agentParams.maxAcceleration = 8.0f;
    agentParams.maxSpeed = 3.5f;
    agentParams.collisionQueryRange = agentParams.radius * 8.0f;
    agentParams.pathOptimizationRange = agentParams.radius * 30.0f;
    agentParams.updateFlags = DT_CROWD_ANTICIPATE_TURNS | 
                             DT_CROWD_OPTIMIZE_VIS |
                             DT_CROWD_OPTIMIZE_TOPO |
                             DT_CROWD_OBSTACLE_AVOIDANCE;
    agentParams.obstacleAvoidanceType = 0;
    agentParams.separationWeight = 2.0f;

    float pos[3] = {1.0f, 0.0f, 1.0f};
    int agent1 = crowd->addAgent(pos, &agentParams);
    
    if (agent1 < 0) {
        std::cerr << "Failed to add agent 1" << std::endl;
    } else {
        std::cout << "Agent 1 added with index: " << agent1 << std::endl;
    }

    pos[0] = 2.0f;
    int agent2 = crowd->addAgent(pos, &agentParams);
    
    if (agent2 < 0) {
        std::cerr << "Failed to add agent 2" << std::endl;
    } else {
        std::cout << "Agent 2 added with index: " << agent2 << std::endl;
    }

    // Check agent count
    int activeCount = crowd->getAgentCount();
    std::cout << "Active agent count: " << activeCount << std::endl;

    // Remove an agent
    if (agent1 >= 0) {
        crowd->removeAgent(agent1);
        std::cout << "Agent 1 removed" << std::endl;
    }

    // Check count after removal
    activeCount = crowd->getAgentCount();
    std::cout << "Active agent count after removal: " << activeCount << std::endl;

    // Clean up
    dtFreeCrowd(crowd);
    dtFreeNavMeshQuery(navQuery);
    dtFreeNavMesh(navMesh);

    std::cout << "Agent add/remove test passed" << std::endl;
}

int main() {
    std::cout << "=== DetourCrowd Basic Tests ===" << std::endl;

    test_basic_crowd_creation();
    test_agent_add_remove();

    std::cout << "\n=== All tests completed ===" << std::endl;
    return 0;
}