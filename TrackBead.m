function [ centres, radii, metrics, badFrames ] = TrackBead( vidObj, contrast, inicoor, varargin )
%TrackBead Uses matlab function do detect dark or bright circles
%   vidObj  : object wrapping the video file
%   contrast: contrast of the bead, either dark or bright
%   inicoor : initial coordinate of the bead
%   range   : the frame range to search for the bead
%   radius  : range of radii of the bead
%   ===============================================================

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

parse(inp, vidObj, contrast, inicoor, varargin{:});

vidObj   = inp.Results.vidObj;
contrast = inp.Results.contrast;
inicoor  = [inp.Results.inicoor(2), inp.Results.inicoor(1)];   % [x,y] -> [r,c]
range    = inp.Results.range;
radius   = inp.Results.radius;
radius(1)= max(radius(1),1);    % make sure lower bound is non-negative
buffer   = inp.Results.buffer;
sensitivity = inp.Results.sensitivity;
edge     = inp.Results.edge;
side     = inp.Results.side;
robust   = inp.Results.robustness;
quality  = inp.Results.quality;
review   = inp.Results.review;
retries  = inp.Results.retries;
% =======================================================================

warn = 1;   % frame number of the last warning
if (range == -1); range = [1, vidObj.Frames]; end;     % set full range, if not given
box = [floor( inicoor - side); ceil( inicoor + side)]; % set box around provided coordinate; [r,c]

radii = zeros( range(2) - range(1) + 1,1);      % preallocate; radii of the beads
centres = zeros( range(2) - range(1) + 1, 2);   % proallocate; centres of the bead
centres(1,:) = double(inicoor);                 % in [r,c] coordinates
metrics = zeros( size(radii,1), 1);             % preallocate; metric of the bead detection
if range(2)-range(1)>0; filmContrast = vidObj.getContrast(); end;            % get a lazy copy of contrast
badFrames = false( size(radii,1),1 );           % preallocate array for bad frames

% indices
failcounter = 0;    % counts failed (empty) detections in a row
frames = 1;         % start from the second frame, the first frame position is given
frame = vidObj.readFrame(range(1));   % set the first frame;
threshRelaxes = [0,0];  % how many times were thresholds relaxed, following poor contrast or metric

% analyze the segment of the video
while( (vidObj.CurrentFrame <= vidObj.Frames) && (range(1) + frames - 1 <= range(2)) ) % while there's another frame to read and not an and of a segment
    
    % search beads using both methods
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

    if(distance(1) == 0 && failcounter < buffer)     % failed to detect anything - 'buffer' consecutive failed detections allowed
        found = false;
        calls = 1;
        while( ~found && calls <= retries );   % try progressively less restrictive search
            found = retry(calls); 
            calls = calls + 1;
        end;
        if ~found;                      % if still nothing is found
            failcounter = failcounter + 1;
            badFrames(frames,:) = true;         % log a bad frame
            centre = centres(max(frames-1,1),:);% [x,y]
            rad = radii(max(frames-1,1),:);     % no modification
            metric = 0;                         % failure metric value is 0
            warning(strjoin({'Bead detection failure at frame',num2str(range(1) + frames - 1),char(10),...
                'Consecutive failures: ', num2str(failcounter),'/',num2str(buffer)}));
        end
    elseif(distance(1) == 0 && failcounter >= buffer)    % 'buffer' failures in a row, abort
        error(strjoin({num2str(buffer),' consecutive failures, abort at frame', num2str(range(1) + frames - 1)}));
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
    if metric < robust - 0.2; badFrames(frames,:) = true; end;

    radius = [max(floor(rad-4),radius(1)), min(ceil(rad+4),radius(2))];     % modify the radius interval (not over 18)
    box = [floor(centre - side); ceil(centre + side)];        % modify the bounding box for the next search

    frames = frames +1;            % increment the frame counter
    frame = vidObj.readFrame();    % read the next frame; frame no.2 during the first run

    if mod(range(1) + frames - 1,100)==0; disp(strjoin({'Bead tracking: ', num2str(range(1) + frames - 1),'/',num2str(range(2))}));end;

end
vidObj.readFrame(range(1)); % return iterator back to the initial frame

% retries the search with relaxed parameters
function [got] = retry(C)
    
    LP = lastPosition();
    thisFrame = range(1) - 1 + frames;
    [c,r,m] = TrackBead(vidObj,contrast,LP,[thisFrame,thisFrame],...
        'radius', radius + [-C,+C], 'sensitivity', min(sensitivity+0.1*C,1), 'edge', max(edge-0.1*C,0),'retries',0);
    
    if m > 0            % if bead is found
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
    
    
end

