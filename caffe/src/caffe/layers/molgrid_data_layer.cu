#include <stdint.h>
#include <vector>
#include "gninasrc/lib/gpu_util.h"
#include <boost/timer/timer.hpp>

#include "caffe/layers/molgrid_data_layer.hpp"


//gridding is implemented in gridmaker
#include "gninasrc/lib/gridmaker.cu"
#define THREADS_PER_BLOCK 512

namespace caffe {

template <typename Dtype>
void MolGridDataLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
		const vector<Blob<Dtype>*>& top)
{
	forward(bottom, top, true);
}

template <typename Dtype>
void MolGridDataLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
		const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom)
{
	backward(top, bottom, true);
}

template <typename Dtype>
void MolGridDataLayer<Dtype>::setAtomGradientsGPU(GridMaker& gmaker, Dtype
        *diff, unsigned batch_size)  {

  unsigned buffersize = 0;
  float4* atoms = NULL;
  short* whichGrid = NULL;
  float3* gradient = NULL; 
  //launch a kernel for each batch
  for (int item_id = 0; item_id < batch_size; ++item_id) {
    int offset = item_id*example_size;
    //malloc and copy batch data
    mol_transform& transform = batch_transform[item_id];
    int natoms = transform.mol.atoms.size();
    
    if(natoms > buffersize) {
        buffersize = natoms;
        if(atoms) {
          cudaFree(atoms);
          cudaFree(whichGrid);
          cudaFree(gradient);
        }
        cudaMalloc(&atoms, sizeof(float4)*natoms);
        cudaMalloc(&whichGrid, sizeof(short)*transform.mol.whichGrid.size());
        cudaMalloc(&gradient, sizeof(float3)*transform.mol.gradient.size());
    }
    cudaMemcpy(atoms, &transform.mol.atoms[0],
            sizeof(float4)*transform.mol.atoms.size(), cudaMemcpyHostToDevice);
    cudaMemcpy(whichGrid, &transform.mol.whichGrid[0],
            sizeof(short)*transform.mol.whichGrid.size(),
            cudaMemcpyHostToDevice);
    cudaMemset(gradient, 0, sizeof(float3)*transform.mol.gradient.size());
    
    gmaker.setCenter(transform.center[0], transform.center[1], transform.center[2]);

    quaternion& cpu_q = transform.Q;
    qt gpu_q(cpu_q.R_component_2(), cpu_q.R_component_3(),
            cpu_q.R_component_4(), cpu_q.R_component_1());
    vec& molcenter = transform.mol.center;
    //diff is batch x channel x X x Y x Z
	unsigned nfull_blocks = natoms / THREADS_PER_BLOCK;
	unsigned nthreads_remain = natoms % THREADS_PER_BLOCK;
    //std::cout << "natoms " << natoms << std::endl;
	boost::timer::cpu_timer time;
    if (nfull_blocks)
        setAtomGradientGPU <<<nfull_blocks, THREADS_PER_BLOCK>>>(gmaker, atoms, 
                whichGrid, gradient, make_float3(molcenter[0], molcenter[1], molcenter[2]), 
                gpu_q, make_float3(transform.center[0], transform.center[1],
                transform.center[2]), diff, offset, 0);
    if (nthreads_remain)
        setAtomGradientGPU <<<1, nthreads_remain>>>(gmaker, atoms, whichGrid, 
                gradient, make_float3(molcenter[0], molcenter[1], molcenter[2]), gpu_q, 
                make_float3(transform.center[0], transform.center[1],
                transform.center[2]), diff, offset, natoms - nthreads_remain);
    cudaStreamSynchronize(cudaStreamPerThread);
//std::cout << "GPU grid time " << time.elapsed().wall/1000000000.0 << "\n";
    cudaMemcpy(&transform.mol.gradient[0], gradient,
            sizeof(float3)*transform.mol.gradient.size(),
            cudaMemcpyDeviceToHost);
  }
  
  if(atoms) {
    cudaFree(atoms);
    cudaFree(whichGrid);
    cudaFree(gradient);
  }
}

template 
void MolGridDataLayer<double>::setAtomGradientsGPU(GridMaker& gmaker, double
        *diff, unsigned batch_size);
template 
void MolGridDataLayer<float>::setAtomGradientsGPU(GridMaker& gmaker, float
        *diff, unsigned batch_size);

INSTANTIATE_LAYER_GPU_FORWARD(MolGridDataLayer);
INSTANTIATE_LAYER_GPU_BACKWARD(MolGridDataLayer);

}  // namespace caffe
