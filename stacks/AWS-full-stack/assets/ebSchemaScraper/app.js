// This solution will inform our team when AWS changes the PHP EB schema version. It is
// not a very good approach (web scrapping), but it's the best we have!
// USAGE:
//     1. Set up env var with EXPECTED_PHP_EB_VERSION to an x.x.x version
//     2. npm install
//     3. node app.js (best to run as a cron)
var cheerio = require('cheerio');
var cheerioTableparser = require('cheerio-tableparser');
var request = require('request');

String.prototype.indexOfEnd = function(string) {
    var io = this.indexOf(string);
    return io == -1 ? -1 : io + string.length;
}

var EXPECTED_VERSION = process.env.EXPECTED_PHP_EB_VERSION || '2.5.0';

request({
    method: 'GET',
    url: 'http://docs.aws.amazon.com/elasticbeanstalk/latest/dg/concepts.platforms.html'
}, function(err, response, body) {
    if (err) return console.error(err);

    $ = cheerio.load(body);
    cheerioTableparser($);

    // Please, AWS, don't change your selectors on us :) :) :)
    var table = $('#concepts\\.platforms\\.PHP')
                  .next()
                  .next()
                  .children('.table-contents')
                  .parsetable(true, true, true);

    var trimmedRow = table[0][3].replace(/ /g,'');

    // Hack because we know where the string is placed
    var endOfWordVersionIndex = trimmedRow.indexOfEnd('version');
    var startOfWord64Bit = trimmedRow.indexOf('64bit');

    var version = trimmedRow.slice(endOfWordVersionIndex, startOfWord64Bit).replace(/(\r\n|\n|\r)/gm, '');

    var expected = EXPECTED_VERSION === version;

    console.log('our version ' + EXPECTED_VERSION);
    console.log('their version ' + version);
    console.log('send report to team? ' + expected);

    // TODO: send out an email if there is a diff
});
