
precision highp float;

in vec2 vTexCoord;

// Camera
uniform vec2 resolution;
uniform vec3 camPos;
uniform vec3 camDir;
uniform vec3 camX;
uniform vec3 camY;
uniform float camFovy; // degrees
uniform float camAspect;
uniform vec3 volMin;
uniform vec3 volMax;
uniform vec3 volCenter;

// Geometry
uniform int Nx;
uniform int Ny;
uniform int Nz;
uniform int Ncol;
uniform int W;
uniform int H;
uniform vec3 L; // world-space extents of grid (also the upper right corner in world space)
uniform float dL;
uniform int Nraymarch;

// Physics
uniform float extinctionScale;
uniform float emissionScale;
uniform float anisotropy;

// Lighting
uniform vec3 skyColor;
uniform vec3 sunColor;
uniform float sunPower;
uniform vec3 sunDir;

// Progressive rendering
uniform int spp;

// Tonemapping
uniform float exposure;
uniform float invGamma;

/////// input buffers ///////
uniform sampler2D Radiance;           // 0 (last frame radiance)
uniform sampler2D RngData;            // 1 (last frame rng seed)
uniform sampler2D absorption_sampler; // 2, vec3 absorption field
uniform sampler2D scattering_sampler; // 3, vec3 scattering field
uniform sampler2D Tair_sampler;       // 4, float temperature field

/////// output buffers ///////
layout(location = 0) out vec4 gbuf_rad;
layout(location = 1) out vec4 gbuf_rng;

/////////////////////// user-defined code ///////////////////////
_USER_CODE_
/////////////////////// user-defined code ///////////////////////


#define M_PI 3.141592653589793
#define sort2(a,b) { vec3 tmp=min(a,b); b=a+b-tmp; a=tmp; }
#define DENOM_EPSILON 1.0e-7

/// GLSL floating point pseudorandom number generator, from
/// "Implementing a Photorealistic Rendering System using GLSL", Toshiya Hachisuka
/// http://arxiv.org/pdf/1505.06022.pdf
float rand(inout vec4 rnd)
{
    const vec4 q = vec4(   1225.0,    1585.0,    2457.0,    2098.0);
    const vec4 r = vec4(   1112.0,     367.0,      92.0,     265.0);
    const vec4 a = vec4(   3423.0,    2646.0,    1707.0,    1999.0);
    const vec4 m = vec4(4194287.0, 4194277.0, 4194191.0, 4194167.0);
    vec4 beta = floor(rnd/q);
    vec4 p = a*(rnd - beta*q) - beta*r;
    beta = (1.0 - sign(p))*0.5*m;
    rnd = p + beta;
    return fract(dot(rnd/m, vec4(1.0, -1.0, 1.0, -1.0)));
}

bool boundsIntersect( in vec3 rayPos, in vec3 rayDir, in vec3 bbMin, in vec3 bbMax,
                      inout float t0, inout float t1 )
{
    vec3 dX = vec3(1.0f/rayDir.x, 1.0f/rayDir.y, 1.0f/rayDir.z);
    vec3 lo = (bbMin - rayPos) * dX;
    vec3 hi = (bbMax - rayPos) * dX;
    sort2(lo, hi);
    bool hit = !( lo.x>hi.y || lo.y>hi.x || lo.x>hi.z || lo.z>hi.x || lo.y>hi.z || lo.z>hi.y );
    t0 = max(max(lo.x, lo.y), lo.z);
    t1 = min(min(hi.x, hi.y), hi.z);
    return hit;
}

float shadowHit(in vec3 rayPos, in vec3 rayDir, in vec3 bbMin, in vec3 bbMax)
{
    // (get first hit assuming rayPos is interior to the AABB)
    vec3 dX = vec3(1.0f/rayDir.x, 1.0f/rayDir.y, 1.0f/rayDir.z);
    vec3 lo = (bbMin - rayPos) * dX;
    vec3 hi = (bbMax - rayPos) * dX;
    sort2(lo, hi);
    return min(min(hi.x, hi.y), hi.z);
}

void constructPrimaryRay(in vec2 frag,
                         inout vec3 rayPos, inout vec3 rayDir)
{
    // Compute world ray direction for given (possibly jittered) fragment
    vec2 ndc = -1.0 + 2.0*(frag/resolution.xy);
    float fh = tan(0.5*radians(camFovy)); // frustum height
    float fw = camAspect*fh;
    vec3 s = -fw*ndc.x*camX + fh*ndc.y*camY;
    rayDir = normalize(camDir + s);
    rayPos = camPos;
}

vec2 slicetoUV(int j, vec3 vsP)
{
    // Given y-slice index j, and continuous voxel space xz-location,
    // return corresponding continuous frag UV for interpolation within this slice
    int row = int(floor(float(j)/float(Ncol)));
    int col = j - row*Ncol;
    vec2 uv_ll = vec2(float(col*Nx)/float(W), float(row*Nz)/float(H));
    float du = vsP.x/float(W);
    float dv = vsP.z/float(H);
    return uv_ll + vec2(du, dv);
}

vec4 interp(in sampler2D S, in vec3 wsP)
{
    vec3 vsP = wsP / dL;
    float pY = vsP.y - 0.5;
    int jlo = clamp(int(floor(pY)), 0, Ny-1); // lower j-slice
    int jhi = clamp(         jlo+1, 0, Ny-1); // upper j-slice
    float flo = float(jhi) - pY;              // lower j fraction
    float fhi = 1.0 - flo;                    // upper j fraction
    vec2 uv_lo = slicetoUV(jlo, vsP);
    vec2 uv_hi = slicetoUV(jhi, vsP);
    vec4 Slo = texture(S, uv_lo);
    vec4 Shi = texture(S, uv_hi);
    return flo*Slo + fhi*Shi;
}

vec3 clampToBounds(in vec3 wsP)
{
    vec3 voxel = vec3(dL);
    return clamp(wsP, voxel, L-voxel);
}


ivec2 mapVsToFrag(in ivec3 vsP)
{
    // map integer voxel space coords to the corresponding fragment coords
    int i = vsP.x;
    int j = vsP.y;
    int k = vsP.z;
    int ui = Nx*j + i;
    int vi = k;
    return ivec2(ui, vi);
}

vec3 sun_transmittance(in vec3 pos, float stepSize, vec4 rnd)
{
    vec3 Tr = vec3(1.0); // transmittance
    float t = shadowHit(pos, sunDir, volMin, volMax);
    float xi = rand(rnd);
    int numSteps = int(ceil(t/stepSize+xi));
    for (int n=0; n<256; ++n)
    {
        if (n>=numSteps) break;
        float dt;
        float tmid;
        if (numSteps==1)
        {
            dt = t;
            tmid = dt*xi;
        }
        else
        {
            float tmin = (float(n) - xi)*stepSize;
            float tmax = min(tmin + stepSize, t);
            tmin = max(0.0, tmin);
            dt = tmax - tmin;
            tmid = 0.5*(tmin+tmax);
        }
        vec3 pMarch = pos + tmid*sunDir;
        vec3 wsP = pMarch - volMin; // transform pMarch into simulation domain:
        vec3 absorption = interp(absorption_sampler, clampToBounds(wsP)).rgb;
        vec3 scattering = interp(scattering_sampler, clampToBounds(wsP)).rgb;
        vec3 sigma_t = (absorption + scattering) * extinctionScale;
        Tr *= exp(-sigma_t*dt); // transmittance over step
    }
    return Tr;
}

float phaseFunction(float mu)
{
    float g = anisotropy;
    float gSqr = g*g;
    return (1.0/(4.0*M_PI)) * (1.0 - gSqr) / pow(1.0 - 2.0*g*mu + gSqr, 1.5);
}

void main()
{
    vec2 frag = gl_FragCoord.xy;
    vec3 rayPos, rayDir;
    constructPrimaryRay(frag, rayPos, rayDir);

    vec3 L = vec3(0.0);
    vec3 Lbackground = skyColor;
    vec3 Tr = vec3(1.0); // transmittance along camera ray

    // jitter raymarch randomly:
    vec4 rnd = texture(RngData, vTexCoord);
    float xi = rand(rnd);
    float lengthScale = length(volMax - volMin);
    float stepSize = lengthScale / float(Nraymarch);

    // intersect ray with volume bounds
    float t0, t1;
    if ( boundsIntersect(rayPos, rayDir, volMin, volMax, t0, t1) )
    {
        float t01 = t1 - t0;
        int numSteps = int(ceil(t01/stepSize+xi));
        numSteps = min(256, numSteps);
        for (int n=0; n<1024; ++n)
        {
            if (n>=numSteps) break;

            // Compute step bounds
            float dt;
            float tmid;
            if (numSteps==1)
            {
                dt = t01;
                tmid = t0 + dt*xi;
            }
            else
            {
                float tmin = t0 + (float(n) - xi)*stepSize;
                float tmax = min(tmin + stepSize, t1);
                tmin = max(t0, tmin);
                dt = tmax - tmin;
                tmid = 0.5*(tmin+tmax);
            }

            // transform pMarch into simulation domain:
            vec3 pMarch = rayPos + tmid*rayDir;
            vec3 wsP = pMarch - volMin;

            // Compute extinction and albedo at step midpoint
            vec3 absorption = interp(absorption_sampler, clampToBounds(wsP)).rgb;
            vec3 scattering = interp(scattering_sampler, clampToBounds(wsP)).rgb;
            vec3 extinction = (absorption + scattering);
            vec3 sigma_t = extinction * extinctionScale;
            vec3 albedo = scattering / max(extinction, vec3(DENOM_EPSILON));

            // Compute in-scattered sunlight
            vec3 Li = sunPower * sunColor * sun_transmittance(pMarch, 3.0*stepSize, rnd);
            vec3 dTr = exp(-sigma_t*dt); // transmittance over step
            vec3 J = Li * albedo * Tr * (vec3(1.0) - dTr); // scattering term integrated over step, assuming constant Li
            L += J * phaseFunction(dot(sunDir, rayDir));

            // Emit radiation from hot air
            float T = interp(Tair_sampler, clampToBounds(wsP)).r;
            vec3 emission = emissionScale * temperatureToEmission(T);
            L += Tr * emission * dt;

            // Update transmittance for start of next step
            Tr *= dTr;
        }
    }

    // Add background "sky" radiance, attenuated by volume
    L += Tr * Lbackground;

    // Add latest radiance estimate to the the Monte Carlo average
    vec4 oldL = vec4(0.0);
    if (spp>0)
        oldL = texture(Radiance, vTexCoord);
    vec3 newL = (float(spp)*oldL.rgb + L) / (float(spp) + 1.0);

    // Output radiance
    gbuf_rad = vec4(newL, 1.0);
    gbuf_rng = rnd;
}

