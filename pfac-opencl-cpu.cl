/**
 * Copyright 2016 Fraser Adams
 *
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 *
 */

/**
 * The following constants have been passed to the OpenCL program by the Host.
 * INVALID
 * MASKBITS
 * MASK
 * WORK_GROUP_SIZE
 * MAX_PATTERN_SIZE
 * WARP_SIZE
 * WARP_SHIFT
 */

/**
 * TODO this program is fairly sub-optimal for a CPU as the use of images and
 * local memory are only really GPU optimisations and are likely to actually
 * slow down a CPU Kernel. The pfacCompact Kernel seems particularly slow, which
 * is most likely due to the synchronisation across Work Groups where it looks
 * like the spinlock sometimes spins for a large number of iterations.
 */

/**
 * Structure to hold the inclusive scan (prefix sum) state information shared
 * across Work Groups. An array of these items is created in global Device
 * memory and used to share state between Work Groups in the pfacCompact
 * Kernel so we can avoid the need to launch multiple Kernels.
 */
typedef struct WorkGroupSum_t {
    int workGroupSum;
    int inclusivePrefix;
} WorkGroupSum;

/**
 * The pfacCompact scan returns an array where each element represents a match
 * and comprises the index within the input and the pattern ID of each match.
 */
typedef struct MatchEntry_t {
    int index;
    int value;
} MatchEntry;

/**
 * 257 is the prime number used in the hash function and has the useful
 * property that we can do reduction modulo 257 using (x & 255) - (x >> 8)
 * http://mymathforum.com/number-theory/11914-calculate-10-7-mod-257-a.html
 */
static inline int mod257(int x) {
    int mod = (x & 255) - (x >> 8);
    if (mod < 0) {
        mod += 257;
    }
    return mod;
}

/**
 * Look up the next state in the hash table given the current state and the
 * transition (input) character. The hash table is held in image1d_buffer_t
 * objects accessed via read_imagei. Note that the initial transition is
 * accessed separately via the initialTransitionsCache in the main Kernel code.
 */
static inline int lookup(image1d_buffer_t hashRow,
                         image1d_buffer_t hashVal,
                         int state,
                         int inputChar) {
    const int2 row = read_imagei(hashRow, state).xy; // hashRow[state]
    const int offset  = row.x;
    int nextState = INVALID;
    if (offset >= 0) {
        const int k_sminus1 = row.y;
        const int sminus1 = k_sminus1 & MASK;
        const int k = k_sminus1 >> MASKBITS; 

        const int p = mod257(k * inputChar) & sminus1;
        const int2 value = read_imagei(hashVal, offset + p).xy; // hashVal[offset + p]
        if (inputChar == value.x) {
            nextState = value.y;
        }
    }
    return nextState;
}

/**
 * Simple PFAC Kernel. Copies WORK_GROUP_SIZE + MAX_PATTERN_SIZE integers from
 * global memory to local (shared) memory for each Work Group (thread block)
 * then transitions the state machine. The state machine holds the initial
 * transition in an array in local memory and the remainder in image1d_buffer_t
 * objects in order to make use of GPU texture memory, which is cached.
 */
__kernel void pfac(image1d_buffer_t initialTransitions,
                   image1d_buffer_t hashRow,
                   image1d_buffer_t hashVal,
                   int initialState,
                   global int* input,
                   global int* output,
                   int inputSize, // Input size in bytes.
                   int n) {
    // Calculate the index of the first character in the Work Group.
    const int firstCharInWorkGroup = get_group_id(0) * WORK_GROUP_SIZE * sizeof(int);

    // Calculate remaining characters, starting from firstCharInWorkGroup.
    const int remaining = inputSize - firstCharInWorkGroup;

    // Calculate the local memory buffer size in bytes, noting that the last
    // work-group may contain fewer characters than the maximum buffer size.
    const int MAX_BUFFER_SIZE = (WORK_GROUP_SIZE + MAX_PATTERN_SIZE) * sizeof(int);
    const int bufferSize = min(remaining, MAX_BUFFER_SIZE);

    const int tid = get_local_id(0); // Thread (Work Item) ID

    int inputIndex  = get_global_id(0);
    int outputIndex = firstCharInWorkGroup + tid;

    // Local (i.e. shared by all threads in the Work Group) memory arrays.
    local int initialTransitionsCache[WORK_GROUP_SIZE];
    local int cache[WORK_GROUP_SIZE + MAX_PATTERN_SIZE];
    local unsigned char* buffer = (local unsigned char*)cache;

    // Load the initialTransitions table to local (shared) memory.
    initialTransitionsCache[tid] = read_imagei(initialTransitions, tid).x;

    // Read input data from global memory to local (shared) memory, n is the
    // number of OpenCL integers that would completely contain the input bytes.
    if (inputIndex < n) {
        cache[tid] = input[inputIndex];
    }

    // Read extra input data as we need overlaps to mitigate boundary condition.
    inputIndex += WORK_GROUP_SIZE;
    if ((inputIndex < n) && (tid < MAX_PATTERN_SIZE)) {
        cache[tid + WORK_GROUP_SIZE] = input[inputIndex];
    }

    // Block until all Work Items in the Work Group have reached this point
    // to ensure correct ordering of memory operations to local memory. 
 	barrier(CLK_LOCAL_MEM_FENCE);

    // Perform state machine look-up with each thread processing four characters.
    #pragma unroll
    for (int i = 0; i < 4; i++) {
        const int j = tid + i * WORK_GROUP_SIZE;
        int pos = j;

        if (pos >= bufferSize) return;

        int match = -1;
        int inputChar = buffer[pos];
        int nextState = initialTransitionsCache[inputChar];
        if (nextState != INVALID) {
            if (nextState < initialState) {
                match = nextState;
//printf("xx matched pattern %d at %d\n", nextState, j);
            }
            pos = pos + 1;
            while (pos < bufferSize) {
                inputChar = buffer[pos];
                nextState = lookup(hashRow, hashVal, nextState, inputChar);
                if (nextState == INVALID) {
                    break;
                }

                if (nextState < initialState) {
                    match = nextState;
//printf("matched pattern %d at %d\n", nextState, j);
                }
                pos = pos + 1;
            }
        }

        // Output results to global memory
        output[outputIndex] = match;
        outputIndex += WORK_GROUP_SIZE;
    }
}


/**
 * PFAC + Compaction Kernel. Copies WORK_GROUP_SIZE + MAX_PATTERN_SIZE integers
 * from global memory to local (shared) memory for each Work Group (thread block)
 * then transitions the state machine. The state machine holds the initial
 * transition in an array in local memory and the remainder in image1d_buffer_t
 * objects in order to make use of GPU texture memory, which is cached.
 *
 * With this kernel after the initial lookup has been performed compaction
 * is carried out to transform the sparse array containing matched pattern IDs
 * into a dense array of index and Pattern ID pairs. For most use cases there
 * should be relatively few matches so compaction of the result set should
 * greatly reduce output bandwidth, however for very large numbers of matches
 * (> input size/2) the required bandwidth would actually be higher as each
 * match returns two ints (index + pattern ID).
 */
__kernel void pfacCompact(image1d_buffer_t initialTransitions,
                          image1d_buffer_t hashRow,
                          image1d_buffer_t hashVal,
                          int initialState,
                          global int* input,
                          global MatchEntry* output,
                          global WorkGroupSum* smem,
                          int inputSize, // Input size in bytes.
                          int n,
                          int limit) {
    const int gid = get_group_id(0); // Work Group ID

    // Calculate the index of the first character in the Work Group.
    const int firstCharInWorkGroup = gid * WORK_GROUP_SIZE * sizeof(int);

    // Calculate remaining characters, starting from firstCharInWorkGroup.
    const int remaining = inputSize - firstCharInWorkGroup;

    // Calculate the local memory buffer size in bytes, noting that the last
    // work-group may contain fewer characters than the maximum buffer size.
    const int MAX_BUFFER_SIZE = (WORK_GROUP_SIZE + MAX_PATTERN_SIZE) * sizeof(int);
    const int bufferSize = min(remaining, MAX_BUFFER_SIZE);

    const int tid = get_local_id(0); // Thread (Work Item) ID

    int inputIndex  = get_global_id(0);

    /**
     * Local (i.e. shared by all threads in the Work Group) memory arrays.
     * Note cache is bigger than the WORK_GROUP_SIZE + MAX_PATTERN_SIZE used in
     * pfac Kernel as the cache is later used in warpScanInclusive where its
     * range will need to be WORK_GROUP_SIZE * chars processed per thread * 2
     */
    local int initialTransitionsCache[WORK_GROUP_SIZE];
    local int cache[WORK_GROUP_SIZE*8];
    local unsigned char* buffer = (local unsigned char*)cache;

    // Load the initialTransitions table to local (shared) memory.
    initialTransitionsCache[tid] = read_imagei(initialTransitions, tid).x;

    // Read input data from global memory to local (shared) memory, n is the
    // number of OpenCL integers that would completely contain the input bytes.
    if (inputIndex < n) {
        cache[tid] = input[inputIndex];
    }

    // Read extra input data as we need overlaps to mitigate boundary condition.
    inputIndex += WORK_GROUP_SIZE;
    if ((inputIndex < n) && (tid < MAX_PATTERN_SIZE)) {
        cache[tid + WORK_GROUP_SIZE] = input[inputIndex];
    }

    // Block until all Work Items in the Work Group have reached this point
    // to ensure correct ordering of memory operations to local memory. 
 	barrier(CLK_LOCAL_MEM_FENCE);

    int match[4] = {-1, -1, -1, -1};

    // Perform state machine look-up with each thread processing four characters.
    #pragma unroll
    for (int i = 0; i < 4; i++) {
        const int j = tid + i * WORK_GROUP_SIZE;
        int pos = j;

        if (pos >= bufferSize) break;

        int inputChar = buffer[pos];
        int nextState = initialTransitionsCache[inputChar];
        if (nextState != INVALID) {
            if (nextState < initialState) {
                match[i] = nextState;
//printf("xx matched pattern %d at %d, i = %d\n", nextState, j, i);
            }
            pos = pos + 1;
            while (pos < bufferSize) {
                inputChar = buffer[pos];
                nextState = lookup(hashRow, hashVal, nextState, inputChar);
                if (nextState == INVALID) {
                    break;
                }

                if (nextState < initialState) {
                    match[i] = nextState;
//printf("matched pattern %d at %d, i = %d\n", nextState, j, i);
                }
                pos = pos + 1;
            }
        }
    }

    // ------------------ Perform Compaction of Match Results ------------------

    /**
     * At this point the state machine look-up has completed and the results for
     * each thread are held in the match array. The next step is to compact the
     * matched patterns and their indexes within each Work Group (thread block).
     * Note that it *may* be possible for steps 1 to 3 of this block to be
     * replaced in OpenCL 2.0 with work_group_scan_inclusive_add, but I don't
     * have any OpenCL 2.0 capable device to be able to test that hypothesis.
     *
     * In order to compact the matched patterns we note that performing a
     * boolean scan (prefix sum) will allow us to determine the index of matching
     * patterns. For example consider the following uncompacted array of matches:
     * 4 7 3 -1 9 5 4 -1 6 2 0 -1 3 9 4 -1 7 5 -1 3 1 2 -1 8 2 4 -1 1 5 9 -1 3
     * 9 1 8 9 -1 2 8 2 4 -1 9 -1 3 5 7 4
     * Which corresponds to bit patterns of the following (-1 equals no match)
     * 11101110111011101101110111011101 1111011110101111
     *
     * Performing a boolean inclusive scan operation will yield:
     * 1 2 3 3 4 5 6 6 7 8 9 9 10 11 12 12
     * 13 14 14 15 16 17 17 18 19 20 20 21 22 23 23 24
     * and
     * 1 2 3 4 4 5 6 7 8 8 9 9 10 11 12 13
     *
     * The value of each scan entry (minus one) thus yields the index in the
     * compacted output array, so for example the entry at index 31 in the
     * uncompacted array will be placed at index 23 in the compacted array.
     *
     * Ideally we would perform a scan over all the matches in the Work Group
     * but for efficiency we partition the scan into scans over 32/64 items
     * corresponding to a warp/wavefront.
     *
     * We are processing WORK_GROUP_SIZE * 4 entries where WORK_GROUP_SIZE
     * corresponds to 256 threads and each thread processes 4 characters thus we
     * have 8 warps each processing 4 characters. We first perform four inclusive
     * scans for each warp (scanning the results for each character processed)
     * the results are held in the scan array. For each scan the final sum is
     * stored in the warpSum shared memory array which, as we have 8 warps each
     * processing 4 characters, is an array of 32 elements indexed via
     * wid + i*WARPS_PER_WORK_GROUP, where wid is the warp ID.
     *
     * From the first step we note that the indexes computed for scan will
     * begin at 1 for each warp, so the second step is to compute the offset
     * required, for example the second block in the example above should really
     * contain the indexes 25 26 27 28 28 29 30 31 32 32 33 33 34 35 36 37
     *
     * The required offsets can be computed by computing a scan of the warpSum
     * entries, noting that because there are 32 entries we can use another
     * warpScanInclusive. For the case of the example above the scan result is
     * 24 37 37 37 37 37 37 37 37 37 37 37 37 37 37 37
     * 37 37 37 37 37 37 37 37 37 37 37 37 37 37 37 37
     *
     * The warpScanInclusive employs padding so we start at index WARP_SIZE - 1
     * (the last pad element) which holds 0, so to retrieve the required warp
     * offset the indexing is via (WARP_SIZE - 1) + wid + i*WARPS_PER_WORK_GROUP.
     * We also subtract one from the scan indexes so they start at zero not one.
     *
     * The third step is to update the scan values with the total warpSum
     * computed for each warp, which means that each scan entry will map to
     * the index of each matching entry within the Work Group. In order to
     * identify the global index however we must now perform another scan
     * (prefix sum) over the workGroupSum (which corresponds to the total
     * number of matches in the Work Group).
     *
     * The fourth step performs synchronisation across Work Groups in order to
     * do a single pass prefix sum across across all Work Groups detailed below.
     *
     * The fifth step uses the inter Work Group prefix sum values computed in
     * step four as globalOffset to perform final compaction as detailed below.
     */
    int scan[4]; // We need an array as we have four results per thread.
    //local int* warpSum = initialTransitionsCache; // Reuse shared memory.
 	barrier(CLK_LOCAL_MEM_FENCE);

    #pragma unroll
    for (int i = 0; i < 4; i++) {
        const int id = tid + i*WORK_GROUP_SIZE;
        cache[id] = (id == 0) ? (match[i] >= 0) : (match[i] >= 0) + cache[id - 1];
        barrier(CLK_LOCAL_MEM_FENCE);
        scan[i] = cache[id] - 1;
//printf("gid %d, tid %d, i %d, idata %d, scan %u\n", gid, tid, i, match[i] >= 0, scan[i]);
    }

    int workGroupSum = cache[4*WORK_GROUP_SIZE - 1];

    /**
     * Step 4: Perform synchronisation across Work Groups in order to do a single
     * pass prefix sum across all Work Groups avoiding the need for multiple
     * Kernels. The approach has been derived from the following research paper:
     * https://research.nvidia.com/sites/default/files/publications/nvr-2016-002.pdf
     * that paper is itself derived from the chained-scan/stream-scan here:
     * https://docs.google.com/viewer?a=v&pid=sites&srcid=ZGVmYXVsdGRvbWFpbnxzaGVuZ2VueWFufGd4OjQ3MjhiOTU3NGRhY2ZlYzA
     */
    cache[0] = 0; // Reuse first local/shared memory entry to store global offset.
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid == 0) {
        /**
         * Store the workGroupSum for the current Work Group and if that is the
         * first Work Group also store workGroupSum to inclusivePrefix. After the
         * write(s) to Global Memory have been made the write_mem_fence ensures
         * the loads will be committed to memory & readable by other Work Groups.
         */
        smem[gid].workGroupSum = workGroupSum;
        write_mem_fence(CLK_GLOBAL_MEM_FENCE);
        if (gid == 0) {
            smem[gid].inclusivePrefix = workGroupSum;
        } else {
            int exclusivePrefix = 0;
            for (int id = gid - 1; id >= 0; id--) {
                // Poll (spinlock) until predecessorWorkGroupSum is set.
                int predecessorWorkGroupSum = -1;
int count = 0; // Deadlock detection TODO it only detects it doesn't fail correctly...
                do { // Force atomic load from global memory.
                    predecessorWorkGroupSum = atomic_add(&smem[id].workGroupSum, 0);
count++;
                } while (predecessorWorkGroupSum == -1 /*&& count < 1000*/);

//if (count > 4000000) printf("gid %d count == %d\n", gid, count);
/*if (count == 1000) {
    printf("\t\tWarning!! gid %d exited polling loop on count == %d\n", gid, count);
}*/

                int predecessorInclusivePrefix = smem[id].inclusivePrefix;
                if (predecessorInclusivePrefix == -1) {
                    exclusivePrefix += predecessorWorkGroupSum;
                } else {
                    exclusivePrefix += predecessorInclusivePrefix;
                    break;
                }
            }

            cache[0] = exclusivePrefix; // Store global offset to shared memory.
            smem[gid].inclusivePrefix = workGroupSum + exclusivePrefix;
        }
        write_mem_fence(CLK_GLOBAL_MEM_FENCE);
    }
 	barrier(CLK_LOCAL_MEM_FENCE);

    int globalOffset = cache[0];
 	barrier(CLK_LOCAL_MEM_FENCE);

//printf("gid %d, tid %d, globalOffset %d\n", gid, tid, globalOffset);
//if (tid == 0) printf("gid %d, workGroupSum = %d, globalOffset = %d\n", gid, workGroupSum, globalOffset);

    /**
     * Step 5: Final compaction. The matching entries are first copied into
     * the local/shared memory cache at the scan indexes computed previously
     * (which are relative to the Work Group). Finally the entries from the
     * cache are copied to the output array, which uses globalOffset to provide
     * the correct global index.
     */
    local MatchEntry* outputCache = (local MatchEntry*)cache;

    #pragma unroll    
    for (int i = 0; i < 4; i++) {
        if (match[i] >= 0) {
            const int index = firstCharInWorkGroup + tid + i*WORK_GROUP_SIZE;
            outputCache[scan[i]].index = index;
            outputCache[scan[i]].value = match[i];
        }
    }
 	barrier(CLK_LOCAL_MEM_FENCE);

    for (int i = tid; i < workGroupSum && globalOffset + i < limit; i += WORK_GROUP_SIZE) {
        output[globalOffset + i] = outputCache[i];
    }
}

