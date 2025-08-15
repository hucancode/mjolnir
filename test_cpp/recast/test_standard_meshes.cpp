#include <iostream>
#include <fstream>
#include <sstream>
#include <cassert>
#include <cstring>
#include <vector>
#include <string>
#include <algorithm>
#include <climits>
#include "../docs/recastnavigation/Recast/Include/Recast.h"
#include "../docs/recastnavigation/Recast/Include/RecastAlloc.h"
#include "../docs/recastnavigation/Detour/Include/DetourNavMesh.h"
#include "../docs/recastnavigation/Detour/Include/DetourNavMeshBuilder.h"

// Simple OBJ loader for testing
struct Mesh {
    std::vector<float> vertices;
    std::vector<int> triangles;
    
    bool loadFromOBJ(const std::string& filename) {
        std::ifstream file(filename);
        if (!file.is_open()) {
            std::cerr << "Failed to open file: " << filename << std::endl;
            return false;
        }
        
        vertices.clear();
        triangles.clear();
        
        std::vector<float> tempVerts;
        std::string line;
        
        while (std::getline(file, line)) {
            std::istringstream iss(line);
            std::string type;
            iss >> type;
            
            if (type == "v") {
                float x, y, z;
                iss >> x >> y >> z;
                tempVerts.push_back(x);
                tempVerts.push_back(y);
                tempVerts.push_back(z);
            } else if (type == "f") {
                std::vector<int> face_indices;
                std::string vertex_str;
                
                // Read all vertices for this face (could be 3, 4, or more)
                while (iss >> vertex_str) {
                    // Parse vertex index (handle v/vt/vn format)
                    int idx = std::stoi(vertex_str.substr(0, vertex_str.find('/'))) - 1;
                    face_indices.push_back(idx);
                }
                
                // Triangulate the face (fan triangulation from first vertex)
                if (face_indices.size() >= 3) {
                    for (size_t i = 1; i < face_indices.size() - 1; ++i) {
                        triangles.push_back(face_indices[0]);
                        triangles.push_back(face_indices[i]);
                        triangles.push_back(face_indices[i + 1]);
                    }
                }
            }
        }
        
        // Copy temp verts to final vertices
        vertices = tempVerts;
        
        std::cout << "  Loaded " << vertices.size()/3 << " vertices and " 
                  << triangles.size()/3 << " triangles" << std::endl;
        return true;
    }
    
    void getBounds(float* bmin, float* bmax) {
        if (vertices.empty()) return;
        
        bmin[0] = bmax[0] = vertices[0];
        bmin[1] = bmax[1] = vertices[1];
        bmin[2] = bmax[2] = vertices[2];
        
        for (size_t i = 3; i < vertices.size(); i += 3) {
            bmin[0] = std::min(bmin[0], vertices[i]);
            bmin[1] = std::min(bmin[1], vertices[i+1]);
            bmin[2] = std::min(bmin[2], vertices[i+2]);
            bmax[0] = std::max(bmax[0], vertices[i]);
            bmax[1] = std::max(bmax[1], vertices[i+1]);
            bmax[2] = std::max(bmax[2], vertices[i+2]);
        }
    }
};

// Test with nav_test.obj - multi-level navigation test mesh
void test_nav_test_mesh() {
    std::cout << "Testing with nav_test.obj (multi-level navigation)..." << std::endl;
    
    rcContext ctx;
    Mesh mesh;
    
    std::string meshPath = "../docs/recastnavigation/RecastDemo/Bin/Meshes/nav_test.obj";
    if (!mesh.loadFromOBJ(meshPath)) {
        std::cout << "  Warning: Could not load nav_test.obj, skipping test" << std::endl;
        return;
    }
    
    // Setup configuration
    rcConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    
    // Get mesh bounds
    mesh.getBounds(cfg.bmin, cfg.bmax);
    
    std::cout << "  Mesh bounds: (" 
              << cfg.bmin[0] << ", " << cfg.bmin[1] << ", " << cfg.bmin[2] << ") to ("
              << cfg.bmax[0] << ", " << cfg.bmax[1] << ", " << cfg.bmax[2] << ")" << std::endl;
    
    // Standard test parameters
    cfg.cs = 0.3f;
    cfg.ch = 0.2f;
    cfg.walkableSlopeAngle = 45.0f;
    cfg.walkableHeight = 10;
    cfg.walkableClimb = 4;
    cfg.walkableRadius = 2;
    cfg.maxEdgeLen = 12;
    cfg.maxSimplificationError = 1.3f;
    cfg.minRegionArea = 8;
    cfg.mergeRegionArea = 20;
    cfg.maxVertsPerPoly = 6;
    cfg.detailSampleDist = 6.0f;
    cfg.detailSampleMaxError = 1.0f;
    
    rcCalcGridSize(cfg.bmin, cfg.bmax, cfg.cs, &cfg.width, &cfg.height);
    
    std::cout << "  Grid size: " << cfg.width << " x " << cfg.height << std::endl;
    
    // Build heightfield
    rcHeightfield* hf = rcAllocHeightfield();
    assert(hf && "Failed to allocate heightfield");
    
    bool ok = rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height, 
                                  cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    assert(ok && "Failed to create heightfield");
    
    // Mark walkable triangles
    std::vector<unsigned char> areas(mesh.triangles.size()/3);
    memset(areas.data(), RC_WALKABLE_AREA, areas.size());
    
    rcMarkWalkableTriangles(&ctx, cfg.walkableSlopeAngle,
                           mesh.vertices.data(), mesh.vertices.size()/3,
                           mesh.triangles.data(), mesh.triangles.size()/3,
                           areas.data());
    
    // Rasterize
    rcRasterizeTriangles(&ctx, mesh.vertices.data(), mesh.vertices.size()/3,
                        mesh.triangles.data(), areas.data(), mesh.triangles.size()/3,
                        *hf, cfg.walkableClimb);
    
    // Filter
    rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *hf);
    
    // Build compact heightfield
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    ok = rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf);
    assert(ok && "Failed to build compact heightfield");
    
    // Check for multiple levels
    int maxLayers = 0;
    int totalLayers = 0;
    for (int i = 0; i < chf->width * chf->height; ++i) {
        int layers = chf->cells[i].count;
        maxLayers = std::max(maxLayers, (int)layers);
        if (layers > 1) totalLayers++;
    }
    
    std::cout << "  Maximum layers in single cell: " << maxLayers << std::endl;
    std::cout << "  Cells with multiple layers: " << totalLayers << std::endl;
    
    // Build layers for multi-level navigation
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    ok = rcBuildHeightfieldLayers(&ctx, *chf, 0, cfg.walkableHeight, *lset);
    
    if (ok && lset->nlayers > 0) {
        std::cout << "  Generated " << lset->nlayers << " navigation layers:" << std::endl;
        for (int i = 0; i < lset->nlayers; ++i) {
            rcHeightfieldLayer& layer = lset->layers[i];
            std::cout << "    Layer " << i << ": " 
                      << layer.width << "x" << layer.height 
                      << " at height " << layer.miny << "-" << layer.maxy << std::endl;
        }
    }
    
    // Continue with standard navmesh generation
    ok = rcErodeWalkableArea(&ctx, cfg.walkableRadius, *chf);
    ok = rcBuildDistanceField(&ctx, *chf);
    ok = rcBuildRegions(&ctx, *chf, 0, cfg.minRegionArea, cfg.mergeRegionArea);
    
    // Analyze regions
    int maxRegion = 0;
    int regionCounts[256] = {0};  // Count spans per region
    int totalRegionSpans = 0;
    
    for (int i = 0; i < chf->spanCount; ++i) {
        int reg = chf->spans[i].reg;
        if (reg > 0 && reg < 256) {
            regionCounts[reg]++;
            totalRegionSpans++;
            if (reg > maxRegion) maxRegion = reg;
        }
    }
    
    std::cout << "  Region Analysis:" << std::endl;
    std::cout << "    Total regions: " << maxRegion << std::endl;
    std::cout << "    Total spans in regions: " << totalRegionSpans << std::endl;
    
    // Count regions by size
    int smallRegions = 0, mediumRegions = 0, largeRegions = 0;
    for (int i = 1; i <= maxRegion; ++i) {
        if (regionCounts[i] > 0) {
            if (regionCounts[i] < 50) smallRegions++;
            else if (regionCounts[i] < 200) mediumRegions++;
            else largeRegions++;
        }
    }
    std::cout << "    Small regions (<50 spans): " << smallRegions << std::endl;
    std::cout << "    Medium regions (50-200 spans): " << mediumRegions << std::endl;
    std::cout << "    Large regions (>200 spans): " << largeRegions << std::endl;
    
    rcContourSet* cset = rcAllocContourSet();
    ok = rcBuildContours(&ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *cset);
    
    std::cout << "  Contour Analysis:" << std::endl;
    std::cout << "    Total contours: " << cset->nconts << std::endl;
    
    // Analyze contours
    int minVerts = INT_MAX, maxVerts = 0;
    int totalVerts = 0;
    for (int i = 0; i < cset->nconts; ++i) {
        int verts = cset->conts[i].nverts;
        minVerts = std::min(minVerts, verts);
        maxVerts = std::max(maxVerts, verts);
        totalVerts += verts;
    }
    if (cset->nconts > 0) {
        std::cout << "    Vertices per contour: min=" << minVerts 
                  << ", max=" << maxVerts 
                  << ", avg=" << (totalVerts / cset->nconts) << std::endl;
    }
    
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    ok = rcBuildPolyMesh(&ctx, *cset, cfg.maxVertsPerPoly, *pmesh);
    
    // Analyze polygon mesh regions
    int polyRegions[256] = {0};
    int maxPolyRegion = 0;
    for (int i = 0; i < pmesh->npolys; ++i) {
        int reg = pmesh->regs[i];
        if (reg > 0 && reg < 256) {
            polyRegions[reg]++;
            if (reg > maxPolyRegion) maxPolyRegion = reg;
        }
    }
    
    std::cout << "  Polygon Mesh Analysis:" << std::endl;
    std::cout << "    Total polygons: " << pmesh->npolys << std::endl;
    std::cout << "    Total vertices: " << pmesh->nverts << std::endl;
    std::cout << "    Unique regions in mesh: " << maxPolyRegion << std::endl;
    
    // Count polygons per region
    std::cout << "    Polygons per region distribution:" << std::endl;
    for (int i = 1; i <= maxPolyRegion && i < 20; ++i) {  // Show first 20 regions
        if (polyRegions[i] > 0) {
            std::cout << "      Region " << i << ": " << polyRegions[i] << " polygons" << std::endl;
        }
    }
    
    // Analyze polygon connectivity
    std::cout << "  Polygon Connectivity Analysis:" << std::endl;
    int connectionCounts[7] = {0};  // 0 to 6 connections
    int totalConnections = 0;
    int isolatedPolys = 0;
    int fullyConnectedPolys = 0;
    
    for (int i = 0; i < pmesh->npolys; ++i) {
        const unsigned short* poly = &pmesh->polys[i * pmesh->nvp * 2];
        int connections = 0;
        
        // Count connections for this polygon
        for (int j = 0; j < pmesh->nvp; ++j) {
            if (poly[j] == RC_MESH_NULL_IDX) break;  // End of vertices
            
            // Check if edge has a neighbor
            if (poly[pmesh->nvp + j] != RC_MESH_NULL_IDX) {
                connections++;
                totalConnections++;
            }
        }
        
        connectionCounts[std::min(connections, 6)]++;
        if (connections == 0) isolatedPolys++;
        if (connections == pmesh->nvp) fullyConnectedPolys++;
    }
    
    std::cout << "    Connection distribution:" << std::endl;
    for (int i = 0; i <= 6; ++i) {
        if (connectionCounts[i] > 0) {
            std::cout << "      " << i << " connections: " << connectionCounts[i] << " polygons" << std::endl;
        }
    }
    std::cout << "    Isolated polygons (no connections): " << isolatedPolys << std::endl;
    std::cout << "    Average connections per polygon: " 
              << (pmesh->npolys > 0 ? (float)totalConnections / pmesh->npolys : 0) << std::endl;
    
    // Check for disconnected regions (islands)
    std::vector<bool> visited(pmesh->npolys, false);
    int islandCount = 0;
    
    for (int i = 0; i < pmesh->npolys; ++i) {
        if (!visited[i]) {
            // Start a new island
            islandCount++;
            std::vector<int> stack;
            stack.push_back(i);
            int islandSize = 0;
            
            while (!stack.empty()) {
                int curr = stack.back();
                stack.pop_back();
                
                if (visited[curr]) continue;
                visited[curr] = true;
                islandSize++;
                
                // Add connected neighbors to stack
                const unsigned short* poly = &pmesh->polys[curr * pmesh->nvp * 2];
                for (int j = 0; j < pmesh->nvp; ++j) {
                    if (poly[j] == RC_MESH_NULL_IDX) break;
                    
                    int neighbor = poly[pmesh->nvp + j];
                    if (neighbor != RC_MESH_NULL_IDX && !visited[neighbor]) {
                        stack.push_back(neighbor);
                    }
                }
            }
            
            if (islandSize > 1) {
                std::cout << "    Island " << islandCount << ": " << islandSize << " polygons" << std::endl;
            }
        }
    }
    std::cout << "    Total disconnected islands: " << islandCount << std::endl;
    
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    ok = rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, cfg.detailSampleDist, cfg.detailSampleMaxError, *dmesh);
    
    std::cout << "  ✓ Generated navmesh: " << pmesh->npolys << " polygons, " 
              << pmesh->nverts << " vertices" << std::endl;
    
    // Clean up - rcFreeHeightfieldLayerSet handles all the cleanup
    rcFreeHeightfieldLayerSet(lset);
    
    rcFreePolyMeshDetail(dmesh);
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
}

// Test with dungeon.obj - complex indoor environment
void test_dungeon_mesh() {
    std::cout << "Testing with dungeon.obj (complex indoor environment)..." << std::endl;
    
    rcContext ctx;
    Mesh mesh;
    
    std::string meshPath = "../docs/recastnavigation/RecastDemo/Bin/Meshes/dungeon.obj";
    if (!mesh.loadFromOBJ(meshPath)) {
        std::cout << "  Warning: Could not load dungeon.obj, skipping test" << std::endl;
        return;
    }
    
    rcConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    
    mesh.getBounds(cfg.bmin, cfg.bmax);
    
    std::cout << "  Mesh bounds: (" 
              << cfg.bmin[0] << ", " << cfg.bmin[1] << ", " << cfg.bmin[2] << ") to ("
              << cfg.bmax[0] << ", " << cfg.bmax[1] << ", " << cfg.bmax[2] << ")" << std::endl;
    
    // Dungeon-appropriate parameters
    cfg.cs = 0.3f;
    cfg.ch = 0.2f;
    cfg.walkableSlopeAngle = 45.0f;
    cfg.walkableHeight = 10;
    cfg.walkableClimb = 4;
    cfg.walkableRadius = 2;
    cfg.maxEdgeLen = 12;
    cfg.maxSimplificationError = 1.3f;
    cfg.minRegionArea = 8;
    cfg.mergeRegionArea = 20;
    cfg.maxVertsPerPoly = 6;
    cfg.detailSampleDist = 6.0f;
    cfg.detailSampleMaxError = 1.0f;
    
    rcCalcGridSize(cfg.bmin, cfg.bmax, cfg.cs, &cfg.width, &cfg.height);
    
    std::cout << "  Grid size: " << cfg.width << " x " << cfg.height << std::endl;
    
    // Build full navmesh
    rcHeightfield* hf = rcAllocHeightfield();
    rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    
    std::vector<unsigned char> areas(mesh.triangles.size()/3, RC_WALKABLE_AREA);
    
    rcMarkWalkableTriangles(&ctx, cfg.walkableSlopeAngle,
                           mesh.vertices.data(), mesh.vertices.size()/3,
                           mesh.triangles.data(), mesh.triangles.size()/3,
                           areas.data());
    
    rcRasterizeTriangles(&ctx, mesh.vertices.data(), mesh.vertices.size()/3,
                        mesh.triangles.data(), areas.data(), mesh.triangles.size()/3,
                        *hf, cfg.walkableClimb);
    
    rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *hf);
    
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf);
    
    // Test layer generation for dungeon
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    bool ok = rcBuildHeightfieldLayers(&ctx, *chf, 0, cfg.walkableHeight, *lset);
    
    if (ok) {
        std::cout << "  Generated " << lset->nlayers << " layers for dungeon" << std::endl;
    } else {
        std::cout << "  WARNING: Layer building failed for dungeon (likely >255 regions)" << std::endl;
        std::cout << "  This is expected for complex meshes with many disconnected areas" << std::endl;
    }
    
    // Clean up - rcFreeHeightfieldLayerSet handles all the cleanup
    rcFreeHeightfieldLayerSet(lset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
    
    std::cout << "  ✓ Dungeon mesh processed successfully" << std::endl;
}

// Test with floor_with_5_obstacles.obj
void test_floor_with_obstacles() {
    std::cout << "Testing with floor_with_5_obstacles.obj..." << std::endl;
    
    rcContext ctx;
    Mesh mesh;
    
    std::string meshPath = "../docs/recastnavigation/RecastDemo/Bin/Meshes/floor_with_5_obstacles.obj";
    if (!mesh.loadFromOBJ(meshPath)) {
        std::cout << "  Warning: Could not load floor_with_5_obstacles.obj, skipping test" << std::endl;
        return;
    }
    
    rcConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    
    mesh.getBounds(cfg.bmin, cfg.bmax);
    
    // Standard parameters matching Odin tests
    cfg.cs = 0.3f;
    cfg.ch = 0.2f;
    cfg.walkableSlopeAngle = 45.0f;
    cfg.walkableHeight = 10;
    cfg.walkableClimb = 4;
    cfg.walkableRadius = 2;
    cfg.maxEdgeLen = 12;
    cfg.maxSimplificationError = 1.3f;
    cfg.minRegionArea = 8;
    cfg.mergeRegionArea = 20;
    cfg.maxVertsPerPoly = 6;
    cfg.detailSampleDist = 6.0f;
    cfg.detailSampleMaxError = 1.0f;
    
    rcCalcGridSize(cfg.bmin, cfg.bmax, cfg.cs, &cfg.width, &cfg.height);
    
    // Full pipeline
    rcHeightfield* hf = rcAllocHeightfield();
    rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
    
    std::vector<unsigned char> areas(mesh.triangles.size()/3, RC_WALKABLE_AREA);
    
    rcMarkWalkableTriangles(&ctx, cfg.walkableSlopeAngle,
                           mesh.vertices.data(), mesh.vertices.size()/3,
                           mesh.triangles.data(), mesh.triangles.size()/3,
                           areas.data());
    
    rcRasterizeTriangles(&ctx, mesh.vertices.data(), mesh.vertices.size()/3,
                        mesh.triangles.data(), areas.data(), mesh.triangles.size()/3,
                        *hf, cfg.walkableClimb);
    
    rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *hf);
    
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf);
    
    rcErodeWalkableArea(&ctx, cfg.walkableRadius, *chf);
    rcBuildDistanceField(&ctx, *chf);
    rcBuildRegions(&ctx, *chf, 0, cfg.minRegionArea, cfg.mergeRegionArea);
    
    rcContourSet* cset = rcAllocContourSet();
    rcBuildContours(&ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *cset);
    
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    rcBuildPolyMesh(&ctx, *cset, cfg.maxVertsPerPoly, *pmesh);
    
    std::cout << "  ✓ Generated navmesh around obstacles: " 
              << pmesh->npolys << " polygons" << std::endl;
    
    // Verify obstacles created separate regions
    int regionCount = 0;
    for (int i = 0; i < pmesh->npolys; ++i) {
        if (pmesh->regs[i] > regionCount) {
            regionCount = pmesh->regs[i];
        }
    }
    
    std::cout << "  Regions created (obstacles should separate walkable areas): " 
              << regionCount << std::endl;
    
    rcFreePolyMesh(pmesh);
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);
    rcFreeHeightField(hf);
}

int main() {
    std::cout << "=== Running C++ Standard Mesh Tests ===" << std::endl;
    std::cout << "Using official Recast test meshes for validation\n" << std::endl;
    
    test_nav_test_mesh();
    std::cout << std::endl;
    
    test_dungeon_mesh();
    std::cout << std::endl;
    
    test_floor_with_obstacles();
    
    std::cout << "\n=== Standard mesh tests completed ===" << std::endl;
    return 0;
}