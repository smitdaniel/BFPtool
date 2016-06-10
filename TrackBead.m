%TrackBead Uses matlab function do detect dark or bright circles
%   IN:
%   vidObj  : object wrapping the video file
%   contrast: contrast of the bead, either dark or bright
%   inicoor : initial coordinate of the bead
%   varargin may contain the following:
%   range   : the frame range to search for the bead
%   radius  : range of radii of the bead
%   buffer  : number of frames of failed detection before aborting
%   sensitivity : sensitivity of the method
%   edge    : edge sensitivity of the method
%   side    : half-side of a box shaper area around last valid detection
%             to search for the bead in the following frame
%   robustness  : how bad can bead metric be
%   imagequality: how bad can image be
%   review  : number of frames averaged to get info about metric and contr.
%   retries : number of retries for one frame (w/ relaxed conditions)
%   retry   : call on this function is a retry from another function run
%   waitbar : handle to figure of tracking progress bar started externally
%   OUT:
%   centres : centres of the detected bead, one centre per frame
%   radii   : radius for each frame of detection
%   metrics : detection strength of each frame
%   badFrames   : frames, where detection failed - surrogative value used
%   DETAIL:
%   The method uses Matlab IP TB method 'imfindcircles' to detect circular
%   objects (here the particular bead of interest), taking into account the
%   spatial distance of the object between consecutive detections. The
%   method uses both algorithms offered by 'imfindcircles' and chooses the
%   best outcome (based on metrics). If the bead is not selected, it
%   retries the selection with relaxed conditions several times. If the
%   metrics or the contrast are poor, it issues warning.
%   ===============================================================

function [ centres, radii, metrics, badFrames ] = TrackBead( vidObj, contrast, inicoor, varargin )

wbThresh = 100;                     % minimal number of frames to track to generate a waitbar

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
defaultWaitbar      = [];
defaultRetry        = false;

addRequired(inp,'vidObj');
addRequired(inp,'contrast');
addRequired(inp,'inicoor');
addOptional(inp,'range',defaultRange,@isnumeric);
addParameter(inp,'radius',defaultRadius,@isnumeric);
addParameter(inp,'buffer',defaultBuffer,@(x) (isnumeric(x) && x > 0));
addParameter(inp,'sensitivity',defaultSensitivity,@isnumeric);
addParameter(inp,'edge',defaultEdge,@isnumeric);
addParameter(inp,'side',defaultSide,@isnumeric);
addParameter(inp,'robustness',defaultRobustness,@isnumeric);
addParameter(inp,'quality',defaultImageQuality,@isnumeric);
addParameter(inp,'review',defaultReview,@isnumeric);
addParameter(inp,'retries',defaultRetries,@isnumeric);
addParameter(inp,'waitbar',defaultWaitbar,@isgraphics);
addParameter(inp,'retry', defaultRetry,@islogical)

parse(inp, vidObj, contrast, inicoor, varargin{:});

vidObj   = inp.Results.vidObj;
contrast = inp.Results.contrast;
inicoor  = [inp.Results.inicoor(2), inp.Results.inicoor(1)];   % [x,y] -> [r,c]
range    = inp.Results.range;
framesToPass = range(2)-range(1)+1; % number of frames to parse
radius   = inp.Results.radius;
radius(1)= max(radius(1),1);    % make sure lower bound is non-negative
radius(2)= max(radius(1),radius(2));    % make sure r(2) >= r(1)
buffer   = inp.Results.buffer;
sensitivity = inp.Results.sensitivity;
edge     = inp.Results.edge;
side     = inp.Results.side;
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
end;

% save radius hard limits (global)
haradius = radius;

% =======================================================================

warn = 1;   % frame number of the last warning
if (range == -1); range = [1, vidObj.Frames]; end;     % set full range, if not given
box = [floor( inicoor - side); ceil( inicoor + side)]; % set box around provided coordinate; [r,c]

radii = zeros( range(2) - range(1) + 1,1);      % preallocate; radii of the beads
centres = zeros( range(2) - range(1) + 1, 2);   % proallocate; centres of the bead
centres(1,:) = double(inicoor);                 % in [r,c] coordinates
metrics = zeros( size(radii,1), 1);             % preallocate; metric of the bead detection
if range(2)-range(1)>0; filmContrast = vidObj.getContrast(range(1),range(2)); end;            % get a lazy copy of contrast
badFrames = false( size(radii,1),1 );           % preallocate array for bad frames

% indices
failcounter = 0;    % counts failed (empty) detections in a row
frames = 1;         % start from the second frame, the first frame position is given
frame = vidObj.readFrame(range(1));   % set the first frame;
threshRelaxes = [0,0];  % how many times were thresholds relaxed, following poor contrast or metric
rmax = size(frame.cdata,1); % number of image data rows
cmax = size(frame.cdata,2); % number of image data columns

% waitbar
if tbSwitch     % do use WB
    if ~isempty(htrackbar)
        wereTracked = htrackbar.UserData.wereTracked;   % get the number of finished frames
        htrackbar.UserData.beadmsg = strjoin({'Tracking bead'});
        wbmsg = strjoin({htrackbar.UserData.intmsg,char(10),htrackbar.UserData.beadmsg});
        waitbar(0,htrackbar,wbmsg);
    else
        htrackbar = waitbar(0,'Tracking bead','Name','Standalone bead tracking');
        htrackbar.UserData.intmsg = 'No ongoing tracking provided';
        htrackbar.UserData.killTrack = false;
        htrackbar.UserData.toBeTracked = framesToPass;
        wereTracked = 0;
    end
end


% analyze the segment of the video
while( (vidObj.CurrentFrame <= vidObj.Frames) && (frames <= framesToPass) ) % while there's another frame to read and not an and of a segment
    
    % ====  INFO SECTION ====
   
    if tbSwitch     % update WB, if any exists
        % check if flag to stop tracking is on or not
        if htrackbar.UserData.killTrack; 
            cleanBreak(true);
            return; 
        end;
        
        trackedRatio = (wereTracked + frames)/htrackbar.UserData.toBeTracked;
        htrackbar.UserData.beadmsg = strjoin({'Tracking bead',char(10),'processing frame',strcat(num2str(frames),'/',num2str(framesToPass)),...
            char(10),'of the current tracking interval.',char(10),'Finished',...
            num2str(round(trackedRatio*100)),'% of total.'});
        wbmsg = strjoin({htrackbar.UserData.intmsg,char(10),htrackbar.UserData.beadmsg});
        waitbar(trackedRatio,htrackbar,wbmsg);
    end       
    
    % ====  THE TRACKING PART   ====
    % search beads using both methods
    if (box(2,1)-box(1,1) < radius(1)) || (box(2,2)-(box(1,2)) < radius(1) ) % search subframe too small
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
    distance = [0,10 + failcounter*5];  % [ index, distance]; initial 'index=0' signals failed detection
    for i=1:size(centre,1)              % go through detected centres
        tmpCentre = [centre(i,2) + box(1,1) - 1, centre(i,1) + box(1,2) - 1]; % transform to coordinates [r,c]
        tmpMoved = norm(centres(max(frames-1,1),:) - tmpCentre)/metric(i);    % calc the distance between the frames
        if(tmpMoved < distance(2) && rad(i) >= radius(1) && rad(i) <= radius(2) ); distance = [i,tmpMoved]; end;   % choose the closest bead
    end;

    if( distance(1) == 0 && failcounter < buffer )     % failed to detect anything - 'buffer' consecutive failed detections allowed
        found = false;
        calls = 1;
        while( ~found && calls <= retries );   % try progressively less restrictive search
            found = retry(calls);
            calls = calls + 1;
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
        centre = [centre(2) + box(1,1) - 1, centre(1) + box(1,2) - 1];  % centre, in global [r,c] coordinates
    end;

    % calculate metric and contrast recent means
    metricTest = mean(metrics( max(frames-review,1):frames ));
    if(range(2)-range(1)>0); contrastTest = mean( filmContrast( max(frames-review,1):frames ));end;

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
    
    centres(frames,:) = centre;      % store the bead centre coordinates [r,c] for the frame
    radii(frames,:)   = rad;
    metrics(frames,:) = metric;
    if metric < robust; badFrames(frames,:) = true; end;

    radius = [max(floor(rad-4),haradius(1)), min(ceil(rad+4),haradius(2))];    % modify the radius interval (not over 18)
    box = [floor(centre - side); ceil(centre + side)];                      % modify the bounding box for the next search
    box(1,1) = max(box(1,1),1);         % do not let the box outside ...
    box(1,2) = max(box(1,2),1);         % ... the frame field
    box(2,1) = min(box(2,1),rmax);
    box(2,2) = min(box(2,2),cmax);
    
    frames = frames +1;            % increment the frame counter
    frame = vidObj.readFrame();    % read the next frame; frame no.2 during the first run

    if mod(range(1) + frames - 1,100)==0; disp(strjoin({'Bead tracking: ', num2str(range(1) + frames - 1),'/',num2str(range(2))}));end;

end
vidObj.readFrame(range(1)); % return iterator back to the initial frame
if tbSwitch
    htrackbar.UserData.wereTracked = wereTracked + framesToPass;  % add frames that were passed
end;
    
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
        'radius', radius + [-C,+C], 'sensitivity', min(sensitivity+0.1*C,1),...
        'edge', max(edge-0.1*C,0),'retries',0, 'retry', true);
    
    if m > 0             % if bead is found
        centre = c;
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

