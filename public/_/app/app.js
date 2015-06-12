// create app
var app = angular.module('cloudpipe', [ 'ngResource', 'ngClipboard' ]);

app.config(['ngClipProvider', function(ngClipProvider) {
    ngClipProvider.setPath("/_/app/ZeroClipboard.swf");
}]);

// create service providing data from data.json
app.factory('status', ['$resource', function ($resource) {
    return $resource('/_/api/list', {}, {
        query: { method:'GET', isArray:false, cache:false }
    });
}]);

app.controller('ListCtrl', [ '$scope', 'status', function ($scope, status) {

    $scope.clientUrl = location.protocol + '//' + location.host;

    $scope.list = status.query();

    $scope.formatDateDiff = function(secs) {
        var diff = (new Date()).getTime() / 1000 - secs;
        if (diff < 60) {
            return Math.round(diff) + ' s';
        } else if (diff < 3600) {
            return Math.round(diff / 60) + ' m';
        } else if (diff < 86400) {
            return Math.round(diff / 3600) + ' h';
        } else {
            return Math.round(diff / 86400) + ' d';
        }
    };

    $scope.formatSize = function(bytes) {
        if (bytes < 1024) {
            return bytes + ' b';
        } else if (bytes < 1048576) {
            return Math.round(bytes / 1024) + ' KB';
        } else if (bytes < 1073741824) {
            return Math.round(bytes / 1048576) + ' MB';
        } else {
            return Math.round(bytes / 1073741824) + ' GB';
        }
    };

    $scope.getClientCode = function() {
        return 'cloud() { test -t 0 && curl -fsSN -H TE:chunked ' + location.protocol + '//' + location.host + '/${1-default} || curl -fsS -T - -H Expect: ' + location.protocol + '//' + location.host + '/${1-default}; }';
    };

    $scope.copiedClientCode = function() {
        alert('Copied. Now find a shell!');
    };

}]);
