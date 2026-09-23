<?php
echo "PHP version: " . phpversion() . "\n";
echo "disable_functions: " . ini_get('disable_functions') . "\n";
echo "system() callable: " . (function_exists('system') && !in_array('system', explode(',', ini_get('disable_functions'))) ? 'yes' : 'no') . "\n";
?>
