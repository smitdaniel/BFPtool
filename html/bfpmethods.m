%% BFPClass methods
% Methods will be explained in detail in this page.
%
% *parameters setting functions*
% (consult _BFPClass_ documentation for parameters details)
%
% * getParameters(Rg,Rc,Rp,P): sets objects values for radii of RBC (Rg),
% RBC-bead contact (Rc), inner pipette radius (Rp) and aspiration pressure
% (P)
% * getBeadParameters(radius,buffer,sensitivity,edge,metric,P2M): sets
% parameters for bead tracking; radius range (radius), maximal number of
% frames of failed tracking (buffer), circle sensitivity (sensitivity),
% edge sensitivity to determine edge pixels (edge), detection strength
% metric threshold (metric), and pixel-to-micron ratio (P2M)
% * getPipetteParameters(correlation,contrast,buffer): sets parameters for
% pipette pattern matching; correlation coefficient threshold
% (correlation), contrast metric threshold (contrast), and maximal number
% of consecutive frames of failed tracking (buffer)
%
% *tracking control function*
%
% * Track(hplot): input is a handle to a target graph, where results of
% tracking are plotted immediatelly after the processing. The function creates a *progress bar*
% indicating percentage of frames finished; this progress bar also allows
% user to cancel the tracking using *Cancel* button. It cycles through the
% intervals contained in object's _intervallist_ variable and for each, it
% calls _TrackPipette_ method and _TrackBead_ method, one after another. If
% tracking fails during an interval, the interval is excluded from the
% results, and momentary results are dumped into the _base_ Matlab
% workspace. On the other hand, the method marks each finished interval as
% tracked by setting its _tracked_ variable to _true_. After all intervals
% have been processed, the method calls _generateReport_ function, to
% generate fidelity summary of tracking. In the end, it plots the results
% into the _hplot_ axes.
%
% *plotting and reports*
%
% * plotTracks(hplot; fInd, lInd, pip, bead, Style, Calibration): only
% required input is the target axes handle, _hplot_, where the function
% outputs. Optional inputs are: 
%
% # fInd: first index of the plotted window; interger
% # lInd: last index of the plotted window; interger
% # pip: switch to plot or not data for the pipette, if applicable; boolean
% # bead: switch to plot or not data for the bead, if applicable; boolean
%
% The remaining options are parameters passed as ('name',value) pair
%
% # Style: a string determining what should be plotted; one of the
% following '3D' (trajectories with time axis), '2D' (trajectories without
% time axis), 'F' (force), 'M' (tracking metric)---default is '3D'
% # Calibration: information, whether the probe has been calibrated;
% boolean (default is false)
%
% * [hrepfig] = generateReport(): takes no inputs and returns a handle to
% the report figure _hrepfig_. Report agregates the _badFrames_ arrays
% returned for each interval by tracking methods. These are the frames,
% where tracking was considerably underperforming or downright failed. The
% method marks intervals of prolonged tracking uncertainty and reports
% explicitly intervals of lower confidence. The report comes with detailed
% explanatory text.
%
% * generateTracks(VideoPath,Name,Profile,Framerate,Sampling): all the
% inputs are parameter. _VideoPath_ is path to the folder where video file
% will be saved (default is the same as the source video), _Name_ is the
% name of the exported video (default is old video name appended by
% 'Tracks.avi'), _Profile_ is the type of the output (default is 'Motion
% JPEG AVI', consult Matlab VideoWriter for more options), _Framerate_ is 
% the framerate of the output in fps (default is 10), _Sampling_ set the 
% rate of sampling from the original video (default  is 1, i.e. every 
% frame is taken). The video is generated with overlaying tracking marks
% (red circles delineating the bead, blue ring delineating the anchor point
% on the pipette) and annotated by the frame index.
%
% *force calculation*
%
% * [overLimit]=getForce(hplot,calib): takes handle to the plot axes
% _hplot_ and information whether the probe has been calibrated _calib_.
% These inputs are passed to plotting function _plotTracks_ when the
% results are plotted by the function. The function returns _overLimit_,
% which is _true_ if RBC extension at any processed frame exceeds
% _linearLimit_. This indicates, that conditions of linear force-strain
% ratio may not hold well at some intervals. The method cycles through all
% thre intervals, excludes those, where tracking failed, and calculates
% force magnitude for each valid frame, based on the detected RBC
% deformation (extension or compression, $\Delta x$) and the stiffness _k_ of the RBC,
% as $F=k\cdot\Delta x$. The unloaded size of the RBC is provided as part
% of _intervallist_. The RBC stiffness is calculated by function
% _getStiffness_.
% * getStiffness(): calculates the stiffness of the bead based on the
% equation 
%
% $$
% k = R_p\Delta P\frac{\pi}{1-\hat{R}_p}\frac{1}{\log\!\left(\!\frac{4}{\hat{R}_c\hat{R}_p}\right)\!-\left(\!1-\frac{1}{4}\hat{R}_p-\frac{3}{8}\hat{R}_p^2+\hat{R}_c^2\right)}
% $$
%
% where $R_p$ is teh pipette radius, $\Delta P$ is the aspiration pressure, $R_c$
% is the contact radius. The radii with a hat sign are normalized by the RBC
% radius $R_g$, i.e. $\hat{R}_p=\frac{R_p}{R_g}$.
%
% *data access*
%
% * [value]=getByFrame(frm,type): returns a requested quantity for a
% requested frame. Two required inputs, _frm_ is _index_ of
% the requested frame, _type_ is the type out of the following list
% 'force' (magnitude of force), 'pipette' (coordinates of pipette anchor),
% 'bead' (coordinates of bead centre), 'metric' (pipette and bead detection
% strength metric).
% * importData(type,data;range): imports outer formatted data into the object. 
% The _data_ must be in collumns, first collumn numbering the frames. _type_ 
% is the type of data of the following list 'force' (forces),
% 'beadPositions' (coordinates of bead centre), 'pipPositions' (coordinates
% of pipette anchor). Parameter _range_ restricts the interval of import.




