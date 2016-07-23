%% Function for tracking bead as s circular object
%   TrackBead Uses Matlab function do detect dark or bright circles
%   *IN:*
%   * vidObj  : object wrapping the video file (vidWrap class)
%   * contrast: contrast of the bead, either 'dark' or 'bright'
%   * inicoor : initial coordinate of the bead
%   varargin may contain the following:
%   * range   : the frame range to search for the bead
%   * radius  : range of radii of the bead
%   * buffer  : number of frames of failed detection before aborting
%   * sensitivity : sensitivity of the method
%   * edge    : edge sensitivity of the method
%   * side    : half-side of a box shaped area around the last valid detection
%               to search for the bead in the following frame
%   * robustness  : bead metric failure threshold
%   * imagequality: image contrast (SD2) relative threshold
%   * review  : number of frames averaged to get info about metric and contr.
%   * retries : max number of retries for one frame (w/ relaxed conditions)
%   * retry   : the flag stating that the call on this function is a retry 
%               from another function run
%   * waitbar : handle to figure of tracking progress bar started externally
%   
%   *OUT:*
%   * centres : centres of the detected bead, one centre per frame
%   * radii   : radius for each frame of detection
%   * metrics : detection strength of each frame
%   * badFrames   : frames, where detection failed - surrogative value used
%   
%   *DETAIL:*
%   The method uses Matlab IP TB method 'imfindcircles' to detect circular
%   objects (here the particular bead of interest), taking into account the
%   spatial distance of the object between consecutive detections. The
%   method uses both algorithms offered by 'imfindcircles' and chooses the
%   best outcome (based on metrics). If the bead is not selected, it
%   retries the selection with relaxed conditions several times. If the
%   metrics or the contrast are poor, it issues warning.
%   ===============================================================


function [ centres, radii, metrics, badFrames ] = TrackBead( vidObj, contrast, inicoor, varargin )

%% ==== Input parser and default definitions ====
wbThresh = 100;     % minimal number of frames to track to generate a waitbar

persistent inp;     % persistent input parser

if isempty(inp)     % create input parser
    inp = inputParser;  
    defaultRange        = -1;           % range of frames to analyze
    defaultRadius       = [8,18];       % range of possible bead radii
    defaultBuffer       = 5;            % number of frames to recover
    defaultSensitivity  = 0.9;          % default general sensitivity of the method
    defaultEdge         = 0.2;          % default value for edge sensitivity
    defaultSide         = [25,25];      % half of the side of the box around the circle, where to search on the next frame
    defaultRobustness   = 0.8;          % level of bead metric considered too poor
    defaultImageQuality = 0.96;         % level of contrast considered too poor
    defaultReview       = 5;            % number of passed frames to calculate metric and contrast states
    defaultRetries      = 5;            % number of retries (conditions are relaxed during each retry)
    defaultWaitbar      = [];           % no default waitbar handle
    defaultRetry        = false;

    addRequired(inp,'vidObj');
    addRequired(inp,'contrast');
    addRequired(inp,'inicoor');
    addOptional(inp,'range',defaultRange,@isnumeric);
    addParameter(inp,'radius',defaultRadius,@isnumeric);
    addParameter(inp,'buffer',defaultBuffer,@(x) (isnumeric(x) && x > 0));
    addParameter(inp,'sensitivity',defaultSensitivity,@isnumeric);
    addParameter(inp,'edge',defaultEdge,@isnumeric);
    addParameter(inp,'side',defaultSide,@(x) (isnumeric(x) && all(x > 0)));
    addParameter(inp,'robustness',defaultRobustness,@isnumeric);
    addParameter(inp,'quality',defaultImageQuality,@isnumeric);
    addParameter(inp,'review',defaultReview,@isnumeric);
    addParameter(inp,'retries',defaultRetries,@isnumeric);
    addParameter(inp,'waitbar',defaultWaitbar,@isgraphics);
    addParameter(inp,'retry', defaultRetry,@islogical)
end

parse(inp, vidObj, contrast, inicoor, varargin{:});

vidObj   = inp.Results.vidObj;
contrast = inp.Results.contrast;
inicoor  = [inp.Results.inicoor(2), inp.Results.inicoor(1)];   % [x,y] -> [r,c]
if (inp.Results.range == -1); 
    range = [1, vidObj.Frames];     % whole video
elseif numel(inp.Results.range)==1
    range = round([inp.Results.range,inp.Results.range]);  % single frame interval
else
    range = round(inp.Results.range);  % defined interval
end;
framesToPass = range(2)-range(1)+1;     % number of frames to parse
radius   = inp.Results.radius;
radius(1)= round(max(radius(1),1));            % make sure lower bound is non-negative
radius(2)= round(max(radius(1),radius(2)));    % make sure r(2) >= r(1); must be intergers
buffer   = round(inp.Results.buffer);
sensitivity = inp.Results.sensitivity;
edge     = inp.Results.edge;
if numel(inp.Results.side)~=2      % if not two side are provided, use default
    side = defaultSide;
else
    side = inp.Results.side;
end
side     = max(side,radius(2)*2);   % make sure the space is large enough, depending on the resolution of the video
robust   = inp.Results.robustness;
quality  = inp.Results.quality;
review   = inp.Results.review;
retries  = inp.Results.retries;
isRetry  = inp.Results.retry;

% if no WB was passed in and the interval is short, do not generate WB
if isempty(inp.Results.waitbar) && framesToPass < wbThresh;
    tbSwitch = false;
else
    tbSwitch = true;
    htrackbar = inp.Results.waitbar;
    wbStep = ceil(framesToPass/100);    % waitbar generated 100 times
end;

% save radius hard limits (global); to avoid invalid radius range
haradius = radius;


%% ==== Set up computation variables ====
% sets OUT variables and temporary variables

warn = 1;   % frame number of the last warning

radii = zeros( range(2) - range(1) + 1,1);      % preallocate; radii of the beads
centres = zeros( range(2) - range(1) + 1, 2);   % proallocate; centres of the bead
centres(1,:) = double(inicoor);                 % in [r,c] coordinates
metrics = zeros( size(radii,1), 1);             % preallocate; metric of the bead detection
filmContrast = vidObj.getContrast(range(1),range(2));   % get a lazy copy of contrast
badFrames = false( size(radii,1),1 );           % preallocate array for bad frames

% indices
failcounter = 0;    % counts failed (empty) detections in a row
frames = 1;         % start from the second frame, the first frame position is given
frame = vidObj.readFrame(range(1));   % set the first frame;
threshRelaxes = [0,0];      % how many times were thresholds relaxed, following poor contrast or metric
rmax = size(frame.cdata,1); % number of image data rows
cmax = size(frame.cdata,2); % number of image data columns
box = [floor( inicoor - side); ceil( inicoor + side)]; % set box around provided coordinate; [r,c]
box(1,1) = max(box(1,1),1);         % do not let the box outside ...
box(1,2) = max(box(1,2),1);         % ... the frame field
box(2,1) = min(box(2,1),rmax);
box(2,2) = min(box(2,2),cmax);

% === waitbar ===
if tbSwitch     % do use WB
    if ~isempty(htrackbar)  % WB already exists yet
        wereTracked = htrackbar.UserData.wereTracked;   % get the number of finished frames
        htrackbar.UserData.beadmsg = strjoin({'Tracking bead'});
        wbmsg = strjoin({htrackbar.UserData.intmsg,char(10),htrackbar.UserData.beadmsg});
        waitbar(0,htrackbar,wbmsg);
    else        % WB need to be created
        htrackbar = waitbar(0,'Tracking bead','Name','Standalone bead tracking');
        htrackbar.UserData.intmsg = 'No ongoing tracking provided';
        htrackbar.UserData.killTrack = false;
        htrackbar.UserData.toBeTracked = framesToPass;
        wereTracked = 0;
    end
end

%% ==== Cycle throught the interval and search the pipette in each frame ====
% analyze the segment of the video
while( (vidObj.CurrentFrame <= vidObj.Frames) && (frames <= framesToPass) ) % while there's another frame to read and not an and of the segment

%% ====  INFO SECTION ====
% If not cancelled, update the progress bar
   
    if tbSwitch     % update WB, if any exists
        % check if flag to stop tracking is on or not (user-canceled from
        % the outside of the fucntion
        if htrackbar.UserData.killTrack; 
            cleanBreak(true);
            return; 
        end;
        
        % update WB every wbStep frames
        % note this is computationally VERY demanding; if the calculation
        % is generally stable, avoid too frequent WB update; default is 100
        % updates per interval
        % TODO: implement the same step for all intervals in one video!
        if ~mod(frames-1,wbStep)
            trackedRatio = (wereTracked + frames)/htrackbar.UserData.toBeTracked;
            htrackbar.UserData.beadmsg = strjoin({'Tracking bead',char(10),'processing frame',strcat(num2str(frames),'/',num2str(framesToPass)),...
                char(10),'of the current tracking interval.',char(10),'Finished',...
                num2str(round(trackedRatio*100)),'% of total.'});
            wbmsg = strjoin({htrackbar.UserData.intmsg,char(10),htrackbar.UserData.beadmsg});
            waitbar(trackedRatio,htrackbar,wbmsg);
        end
    end       
    
%% ====  THE TRACKING PART   ====
% Search the bead using both Two-stage and Phase-code methods and consider
% also the distance between two consecutive frames

    if (box(2,1)-box(1,1) < radius(1)) || (box(2,2)-(box(1,2)) < radius(1)) % search subframe too small (bead was likely detected at the frame edge)
        cleanBreak(false);
        warndlg(strjoin({'A tracking subframe became too small at the frame', num2str(range(1) + frames - 1),...
            'The bead strayed too close to the edge or the traking failed in the last few frames.',...
            'The interval will be excluded from the tracking.'}),...
            'Bead detection failure', 'replace');
        return;
    end
        
    subframe = double(frame.cdata( box(1,1):box(2,1), box(1,2):box(2,2) ));       % area to search for the circle
    [centre,rad,metric] = imfindcircles(subframe, radius, 'ObjectPolarity',contrast,...
        'Sensitivity',sensitivity,'Method','TwoStage','EdgeThreshold', edge);     % this method returns in [x,y] format
    [centrePC,radPC,metricPC] = imfindcircles(subframe, radius, 'ObjectPolarity',contrast,...
        'Sensitivity',sensitivity,'Method','PhaseCode','EdgeThreshold', edge);    % this method returns in [x,y] format

    % concatenate output from both methods for further processing
    centre = [ centre; centrePC ];  % [r,c] coordinates
    rad = [rad; radPC ];
    metric = [metric; metricPC ];
    
    % select the strongest circle: select the closest bead,metric-weighted
    distance = [0, 0];  % [ index, distance]; initial 'index=0' signals failed detection
    for i=1:size(centre,1)              % go through detected centres
        tmpCentre = [centre(i,2) + box(1,1) - 1, centre(i,1) + box(1,2) - 1]; % transform to coordinates [r,c]
        tmpDist = max( norm(centres(max(frames-1,1),:)-tmpCentre), radius(1) )/radius(1);
        tmpMoved = metric(i) / tmpDist;
        if(tmpMoved > distance(2) && rad(i) >= radius(1) && rad(i) <= radius(2) ); distance = [i,tmpMoved]; end;   % choose the closest bead
    end;
    
    if( distance(1) == 0 && failcounter < buffer )     % failed to detect anything -- 'buffer' consecutive failed detections allowed
        found = false;
        calls = 1;
        while( ~found && calls <= retries );    % try progressively less restrictive search
            found = retry(calls);               % this block is not called during a retry call
            calls = calls + 1;                  % retry call has 0 retries
        end;
        if ~found;                              % if still nothing is found 
            failcounter = failcounter + 1;
            badFrames(frames,:) = true;         % log a bad frame
            centre = centres(max(frames-1,1),:);% [x,y]
            rad = radii(max(frames-1,1),:);     % no modification
            metric = 0;                         % failure metric value is 0
            if (calls==retries+1 && ~isRetry)   % if detection fails for all retries, and is not one of the retries
                warning(strjoin({'Bead detection failure at frame',num2str(range(1) + frames - 1),char(10),...
                'Consecutive failures: ', num2str(failcounter),'/',num2str(buffer)}));
            end;
        else    % if a bead is found during retries cycle
            centre = [centre(2) + box(1,1) - 1, centre(1) + box(1,2) - 1];
        end
            
    elseif(distance(1) == 0 && failcounter >= buffer)   % 'buffer' failures in a row, abort
        cleanBreak(false);
        warndlg(strjoin({num2str(buffer), 'consecutive frame failures, detection failed at frame',...
                    [num2str(thisFrame),'.'],'The interval will be excluded from the results.'}),...
                    'Bead detection failure','replace');    % inform about detection fail before return
        return;
    else                                % detection successful, save new centre
        failcounter = 0;                % reset failcounter after a successful detection
        centre = centre(distance(1),:); % keep only the closest circle, still in [x,y]
        rad = rad(distance(1),:);
        metric = metric(distance(1),:);
        if ~isRetry     % retry call works only locally; returns coordinate in the box
            centre = [centre(2) + box(1,1) - 1, centre(1) + box(1,2) - 1];  % centre, in global [r,c] coordinates
        end
    end;

    %% ==== calculate metric and contrast recent means ====
    % calculates metrics to assure tracking quality; averaging to avoid
    % reaction to outliers
    
    metricTest = mean(metrics( max(frames-review,1):frames ));
    contrastTest = mean( filmContrast( max(frames-review,1):frames ));

    % adapt thresholds if quality of descriptors is low
    if ( metricTest < robust - threshRelaxes(1) * 0.05 ...
            || contrastTest < quality - threshRelaxes(2) * 0.05 ...
            && range(1)+frames < range(2) )
        if frames-warn > 10
            warning(strjoin({'At frame %d, the value of detection metric or video contrast are low \n',...
                'Detection metric: %.3f/%.3f \n Contrast: %.3f/%.3f \n',...
                'If possible, sensitivity will be increased and thresholds lowered.'}),...
                range(1)-1+frames, metricTest, robust - threshRelaxes(1)*0.05,...
                contrastTest, quality - threshRelaxes(2) * 0.05 );
            warn = frames;
        end
        if sensitivity < 0.9;
            threshRelaxes(1) = threshRelaxes(1) + 1;
            sensitivity = sensitivity + 0.1;
        end;
        if edge > 0.1;
            threshRelaxes(2) = threshRelaxes(2) + 1;
            edge = edge - 0.1;
        end;    
    else        
        if threshRelaxes(1) > 0;
            threshRelaxes(1) = threshRelaxes(1) - 1;
            sensitivity = sensitivity - 0.1;
        end;
        if threshRelaxes(2) > 0;
            threshRelaxes(2) = threshRelaxes(2) - 1;
            edge = edge + 0.1;
        end        
    end
    
    %% Save and prepare for the next run
    centres(frames,:) = centre;      % store the bead centre coordinates [r,c] for the frame
    radii(frames,:)   = rad;
    metrics(frames,:) = metric;
    if metric < robust; badFrames(frames,:) = true; end;

    radius = [max(floor(rad-4),haradius(1)), min(ceil(rad+4),haradius(2))]; % modify the radius interval (not over 18)
    if radius(2)<= radius(1); radius=haradius; end;                         % if radius setting fails, reset
    box = [floor(centre - side); ceil(centre + side)];                      % modify the bounding box for the next search
    box(1,1) = max(box(1,1),1);         % do not let the box outside ...
    box(1,2) = max(box(1,2),1);         % ... the frame field
    box(2,1) = min(box(2,1),rmax);
    box(2,2) = min(box(2,2),cmax);
    
    frames = frames +1;            % increment the frame counter
    frame = vidObj.readFrame();    % read the next frame; frame no.2 during the first run

    if mod(range(1) + frames - 1,100)==0; disp(strjoin({'Bead tracking: ', num2str(range(1) + frames - 1),'/',num2str(range(2))}));end;

end
%% ==== After-search clean-up ====
vidObj.readFrame(range(1)); % return iterator back to the initial frame
if tbSwitch
    htrackbar.UserData.wereTracked = wereTracked + framesToPass;  % add frames that were passed
end;

%% ==== Nested functions ====
% retries the search with relaxed parameters
function [got] = retry(C)
    
    if C < 1;
        warning(strjoin({'Retry function of bead tracking method was passed a negative argument,',...
            'which is illegal. Frame:',[num2str(range(1)-1+frames),'.'],'No retry will be run.'}));
        return;
    end;
    
    LP = lastPosition();
    thisFrame = range(1) - 1 + frames;
    [c,r,m] = TrackBead(vidObj,contrast,LP,[thisFrame,thisFrame],...
        'radius', max(radius + [-C,+C],1), 'sensitivity', min(sensitivity+0.1*C,1),...
        'edge', max(edge-0.1*C,0),'retries',0, 'retry', true,'side',side + [2,2]*C);
    
    if m > 0             % if a bead is found
        centre = c - [2,2]*C;   % correct the box shift, before global coordinates calculated in the main run
        rad    = r;
        metric = m;
        got =  true;
    else
        got = false;
    end
    
end

% returns last detected position of the bead in coordinates [x,y]
function [LP] = lastPosition()
    if frames > 1
        LP = [centres(frames-1,2), centres(frames-1,1)];
    else
        LP = [inicoor(2),inicoor(1)];
    end
end

% If the function is shut down or fails, return cleanly
function [] = cleanBreak(user)    
    centres(frames:end,:)     = [];                 % crop zeros...
    radii(frames:end,:)       = [];
    metrics(frames:end,:)     = [];
    badFrames(frames:end,:)   = [];
    vidObj.readFrame(range(1));                     % reset the first frame;     
    if ~user;   % failure, not cancelled by the user
        htrackbar.UserData.failure = true;          % report tracking failed
        htrackbar.UserData.wereTracked = wereTracked + framesToPass;    % report the interval as parsed
    else 
        htrackbar.UserData.wereTracked = wereTracked;   % cancelled tracking, reset the counter
        htrackbar.UserData.killTrack = true;            % kill tracking
    end;
end
  
end

% last visit on July 23